' Keeps an anonymous Twitch IRC connection open, loads emotes/badges/history in parallel,
' and hands the Chat overlay small batches of ready-to-draw messages (~10 per second).
' Each message is held for delayMs after it arrives; the overlay keeps that in step with
' how far behind live the video is (or 0 for real time).

sub init()
    m.top.functionName = "main"
end sub

sub main()
    m.channel = LCase(m.top.channel)
    if m.channel = "" then return
    m.port = CreateObject("roMessagePort")
    m.clock = CreateObject("roTimespan")
    m.crlf = Chr(13) + Chr(10)
    m.delayMs = m.top.delayMs
    ' In arrival order: { t: arrival time in ms, line } for live chat, released at t + delayMs;
    ' { line } for history and { system: text } for notices, released right away.
    m.inbox = []
    m.requests = {}
    m.emoteLists = {}
    m.badges = {}
    m.seenIds = {}
    m.seenOrder = []
    m.sources = chatEmoteSources(m.top.channelId, m.top.providers)
    m.tokenizer = createChatTokenizer(buildChatEmoteMap(m.sources, m.emoteLists))
    m.ready = false
    m.firstFlush = true
    m.lastFlush = 0
    m.sock = invalid
    m.rxCarry = CreateObject("roByteArray")
    m.rxText = ""
    m.reconnectAt = 0
    m.backoffMs = 1000
    m.lastRx = 0
    m.pingAt = 0
    m.connected = false
    m.lostNoticeShown = false
    m.sizeQueue = [] ' BTTV emotes waiting for a HEAD request before they may animate
    m.sizeChecks = 0
    m.stats = newChatStats()
    m.top.observeField("control", m.port)
    m.top.observeField("delayMs", m.port)

    for each source in m.sources
        startRequest(source.key, source.url, invalid, invalid)
    end for
    deviceId = get_user_setting("device_code", "")
    for each gql in [chatBadgeRequest(m.channel, deviceId), chatTwitchEmotesRequest(m.channel, deviceId)]
        startRequest(gql.key, gql.url, gql.body, gql.headers)
    end for
    if m.top.history
        startRequest("history", "https://recent-messages.robotty.de/api/v2/recent-messages/" + m.channel + "?limit=50&hide_moderation_messages=true&hide_moderated_messages=true", invalid, invalid)
    end if
    connectIrc()

    while true
        timeout = 1000
        if m.inbox.Count() > 0 or m.reconnectAt > 0 then timeout = 50
        msg = wait(timeout, m.port)
        msgType = type(msg)
        if msgType = "roSocketEvent"
            if m.sock <> invalid and msg.getSocketID() = m.sock.getID() then readSocket()
        else if msgType = "roUrlEvent"
            onRequestDone(msg)
        else if msgType = "roSGNodeEvent"
            if msg.getField() = "control" and LCase(msg.getData()) = "stop" then exit while
            if msg.getField() = "delayMs" then m.delayMs = msg.getData()
        end if

        now = m.clock.TotalMilliseconds()
        ' Hold the first batch until emotes and history load (at most 10s; big 7TV sets are
        ' over 1 MB) so early messages already show their emotes.
        if not m.ready and (m.requests.Count() = 0 or now >= 10000)
            m.ready = true
            ? getLogTimestamp(); " [ChatJob] ready after "; now; "ms with "; m.tokenizer.emotes.Count(); " emotes, "; m.badges.Count(); " badges, "; m.tokenizer.twitchAnimated.Count(); " animated Twitch emotes"
        end if
        if m.ready and now - m.lastFlush >= 100
            flushInbox(now)
        end if
        if now - m.stats.since >= 30000 then logChatStats(now)
        checkConnection(now)
    end while
    closeIrc()
end sub

function newChatStats() as object
    return { since: 0, messages: 0, twitch: 0, thirdParty: 0, animated: 0, emoji: 0 }
end function

' One line every 30s so emote problems can be read from the debug console (port 8085).
sub logChatStats(now as integer)
    s = m.stats
    if s.messages > 0
        ? getLogTimestamp(); " [ChatJob] last 30s: "; s.messages; " messages, "; s.twitch; " Twitch emotes, "; s.thirdParty; " 7TV/BTTV/FFZ emotes ("; s.animated; " animated), "; s.emoji; " emoji, delay "; m.delayMs; "ms"
    end if
    m.stats = newChatStats()
    m.stats.since = now
end sub

sub connectIrc()
    closeIrc()
    now = m.clock.TotalMilliseconds()
    m.rxCarry = CreateObject("roByteArray")
    m.rxText = ""
    address = CreateObject("roSocketAddress")
    address.setAddress("irc.chat.twitch.tv:6667")
    sock = CreateObject("roStreamSocket")
    sock.setSendToAddress(address)
    if not sock.connect()
        sock.close()
        scheduleReconnect(now, false)
        return
    end if
    ' Anonymous read-only login, so no account token ever goes over this plain-text socket.
    nick = "justinfan" + (10000 + Rnd(89999)).ToStr()
    sock.sendStr("CAP REQ :twitch.tv/tags twitch.tv/commands" + m.crlf + "PASS SCHMOOPIIE" + m.crlf + "NICK " + nick + m.crlf + "JOIN #" + m.channel + m.crlf)
    sock.setMessagePort(m.port)
    sock.notifyReadable(true)
    m.sock = sock
    m.lastRx = now
    m.pingAt = 0
    if sock.getCountRcvBuf() > 0 then readSocket()
end sub

sub closeIrc()
    if m.sock <> invalid
        m.sock.notifyReadable(false)
        m.sock.close()
        m.sock = invalid
    end if
end sub

' Closes the socket and retries with exponential backoff (immediately for a server RECONNECT).
sub scheduleReconnect(now as integer, immediate as boolean)
    closeIrc()
    if m.connected and not m.lostNoticeShown
        m.lostNoticeShown = true
        m.inbox.Push({ system: "Chat connection lost. Reconnecting..." })
    end if
    if immediate
        m.reconnectAt = now + 1
    else
        m.reconnectAt = now + m.backoffMs
        m.backoffMs = m.backoffMs * 2
        if m.backoffMs > 30000 then m.backoffMs = 30000
    end if
end sub

sub checkConnection(now as integer)
    if m.sock = invalid
        if m.reconnectAt > 0 and now >= m.reconnectAt
            m.reconnectAt = 0
            connectIrc()
        end if
        return
    end if
    ' Twitch pings every ~5 minutes; ping it ourselves after a quiet minute so a dead
    ' connection is noticed within ~75 seconds instead.
    if m.pingAt = 0 and now - m.lastRx > 60000
        sendLine("PING :stitch")
        m.pingAt = now
    else if m.pingAt > 0 and now - m.pingAt > 15000
        scheduleReconnect(now, false)
    end if
end sub

sub sendLine(text as string)
    if m.sock <> invalid then m.sock.sendStr(text + m.crlf)
end sub

' Reads everything waiting on the socket and handles each complete line. A UTF-8 character
' cut off at the end of a read is held back (as bytes) and the unfinished line is kept (as
' text) for the next read, so nothing is ever decoded in halves.
sub readSocket()
    count = m.sock.getCountRcvBuf()
    if count <= 0
        ' Readable with nothing to read means Twitch closed the connection.
        if m.sock.isReadable() then scheduleReconnect(m.clock.TotalMilliseconds(), false)
        return
    end if
    chunk = CreateObject("roByteArray")
    chunk[count - 1] = 0
    received = m.sock.receive(chunk, 0, count)
    if received <= 0 then return
    while chunk.Count() > received
        chunk.Pop()
    end while
    bytes = chunk
    if m.rxCarry.Count() > 0
        bytes = m.rxCarry
        bytes.Append(chunk)
    end if
    m.rxCarry = CreateObject("roByteArray")
    cut = utf8IncompleteTail(bytes)
    if cut > 0
        held = []
        for i = 1 to cut
            held.Unshift(bytes.Pop())
        end for
        for each b in held
            m.rxCarry.Push(b)
        end for
    end if

    lines = (m.rxText + bytes.ToAsciiString()).Split(Chr(10))
    m.rxText = lines.Pop() ' unfinished last line, "" when the read ended on a newline
    if m.rxText.Len() > 65536 then m.rxText = "" ' runaway data that will never form a line

    now = m.clock.TotalMilliseconds()
    for each line in lines
        if line.Right(1) = Chr(13) then line = line.Left(line.Len() - 1)
        if line <> "" then handleLine(line, now)
    end for
end sub

' How many bytes at the end start a UTF-8 character without finishing it (0-3).
function utf8IncompleteTail(bytes as object) as integer
    count = bytes.Count()
    i = count - 1
    while i >= 0 and count - i <= 3 and (bytes[i] and &hC0) = &h80
        i = i - 1
    end while
    if i < 0 then return 0
    lead = bytes[i]
    need = 1
    if (lead and &hE0) = &hC0
        need = 2
    else if (lead and &hF0) = &hE0
        need = 3
    else if (lead and &hF8) = &hF0
        need = 4
    end if
    if need > count - i then return count - i
    return 0
end function

sub handleLine(line as string, now as integer)
    m.lastRx = now
    m.pingAt = 0
    if line.Left(5) = "PING "
        sendLine("PONG " + line.Mid(5))
    else if line.Instr(" PRIVMSG #") > 0 or line.Instr(" USERNOTICE #") > 0 or isModerationLine(line)
        m.inbox.Push({ t: now, line: line })
        if m.inbox.Count() > 800 then m.inbox.Shift()
    else
        msg = parseIrcLine(line)
        if msg = invalid then return
        if msg.command = "001"
            m.backoffMs = 1000
            if m.lostNoticeShown
                m.inbox.Push({ system: "Reconnected to chat." })
            end if
            m.connected = true
            m.lostNoticeShown = false
        else if msg.command = "RECONNECT"
            scheduleReconnect(now, true)
        end if
    end if
end sub

function isModerationLine(line as string) as boolean
    return line.Instr(" CLEARCHAT #") > 0 or line.Instr(" CLEARMSG #") > 0
end function

' Sends every message whose release time has passed. Works newest-first so a flood only
' pays to parse the messages that will actually be drawn; moderation events always pass.
sub flushInbox(now as integer)
    m.lastFlush = now
    released = []
    ' Release time is worked out here rather than on arrival, so a delay change (the video
    ' falling further behind live, or catching up) applies to messages already waiting.
    while m.inbox.Count() > 0
        arrived = m.inbox[0].t
        if arrived <> invalid and arrived + m.delayMs > now then exit while
        released.Push(m.inbox.Shift())
    end while
    if released.Count() = 0 then return

    limit = 12
    if m.firstFlush then limit = 60
    m.firstFlush = false
    batch = []
    shown = 0
    for i = released.Count() - 1 to 0 step -1
        entry = released[i]
        item = invalid
        if entry.system <> invalid
            item = { kind: "system", text: entry.system, id: "", login: "" }
        else if shown < limit or isModerationLine(entry.line)
            item = buildChatItem(entry.line)
        end if
        if item <> invalid
            batch.Unshift(item)
            if item.kind <> "clear" and item.kind <> "delete" then shown = shown + 1
            ' A full chat clear wipes everything older, so stop there.
            if item.kind = "clear" and item.login = "" then exit for
        end if
    end for
    if batch.Count() > 0 then m.top.messages = batch
    queueSizeChecks()
end sub

' Starts HEAD requests for animated BTTV emotes seen for the first time, four at a time.
' They animate meanwhile; afterwards only files small enough keep animating.
sub queueSizeChecks()
    if m.tokenizer.pendingChecks.Count() > 0
        m.sizeQueue.Append(m.tokenizer.pendingChecks)
        m.tokenizer.pendingChecks = []
    end if
    while m.sizeChecks < 4 and m.sizeQueue.Count() > 0
        entry = m.sizeQueue.Shift()
        transfer = createTransfer(entry.check)
        if transfer.asyncHead()
            m.requests[transfer.getIdentity().ToStr()] = { key: "size", transfer: transfer, entry: entry }
            m.sizeChecks = m.sizeChecks + 1
        end if
    end while
end sub

' Turns one IRC line into a render item for the overlay, or invalid if there's nothing to show.
function buildChatItem(line as string) as dynamic
    msg = parseIrcLine(line)
    if msg = invalid then return invalid
    tags = msg.tags
    command = msg.command
    if command = "CLEARCHAT"
        return { kind: "clear", login: msg.trailing }
    else if command = "CLEARMSG"
        if tags["target-msg-id"] = invalid then return invalid
        return { kind: "delete", id: tags["target-msg-id"] }
    else if command <> "PRIVMSG" and command <> "USERNOTICE"
        return invalid
    end if

    id = tags["id"]
    if id = invalid then id = ""
    if id <> ""
        ' History and the live connection can overlap by a moment; show each message once.
        if m.seenIds.DoesExist(id) then return invalid
        m.seenIds[id] = true
        m.seenOrder.Push(id)
        if m.seenOrder.Count() > 500 then m.seenIds.Delete(m.seenOrder.Shift())
    end if

    login = msg.nick
    if tags["login"] <> invalid then login = tags["login"]
    name = tags["display-name"]
    if name = invalid or name = "" then name = login

    item = {
        kind: "msg",
        id: id,
        login: login,
        name: name,
        color: chatNameColor(tags["color"], login),
        badges: chatBadgeUrls(tags["badges"]),
        tokens: [],
        action: false
    }
    text = msg.trailing
    if text.Left(8) = Chr(1) + "ACTION "
        item.action = true
        text = text.Mid(8)
        if text.Right(1) = Chr(1) then text = text.Left(text.Len() - 1)
    end if
    if text <> ""
        item.tokens = tokenizeChatMessage(text, parseTwitchEmoteRanges(text, tags["emotes"]), m.tokenizer)
    end if
    m.stats.messages = m.stats.messages + 1
    for each token in item.tokens
        if token.emoji = true
            m.stats.emoji = m.stats.emoji + 1
        else if token.url <> invalid
            if token.url.Instr("static-cdn.jtvnw.net") >= 0
                m.stats.twitch = m.stats.twitch + 1
            else
                m.stats.thirdParty = m.stats.thirdParty + 1
            end if
            if token.anim <> invalid then m.stats.animated = m.stats.animated + 1
        end if
    end for

    if command = "USERNOTICE"
        item.kind = "notice"
        item.notice = ""
        if tags["system-msg"] <> invalid then item.notice = unescapeIrcTagValue(tags["system-msg"])
        if item.notice = "" and item.tokens.Count() = 0 then return invalid
    else if item.tokens.Count() = 0
        return invalid
    end if
    return item
end function

function chatBadgeUrls(badgesTag as dynamic) as object
    urls = []
    if badgesTag = invalid or badgesTag = "" then return urls
    for each badge in badgesTag.Split(",")
        url = m.badges[badge]
        if url <> invalid then urls.Push(url)
    end for
    return urls
end function

function createTransfer(url as string) as object
    transfer = CreateObject("roUrlTransfer")
    transfer.setMessagePort(m.port)
    transfer.setUrl(url)
    transfer.setCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.initClientCertificates()
    transfer.enableEncodings(true)
    transfer.retainBodyOnError(true)
    return transfer
end function

sub startRequest(key as string, url as string, body as dynamic, headers as dynamic)
    transfer = createTransfer(url)
    if headers <> invalid then transfer.setHeaders(headers)
    started = false
    if body <> invalid
        started = transfer.asyncPostFromString(body)
    else
        started = transfer.asyncGetToString()
    end if
    if started
        ' Keep a reference so the transfer isn't garbage collected (and cancelled) mid-flight.
        m.requests[transfer.getIdentity().ToStr()] = { key: key, transfer: transfer, started: m.clock.TotalMilliseconds() }
    else
        ? getLogTimestamp(); " [ChatJob] "; key; " request could not start"
    end if
end sub

sub onRequestDone(msg as object)
    if msg.getInt() <> 1 then return
    id = msg.getSourceIdentity().ToStr()
    request = m.requests[id]
    if request = invalid then return
    m.requests.Delete(id)
    key = request.key
    code = msg.getResponseCode()
    if key = "size"
        m.sizeChecks = m.sizeChecks - 1
        if code <> 200 then ? getLogTimestamp(); " [ChatJob] size check failed for "; request.entry.name; ": HTTP "; code; " "; msg.getFailureReason()
        applyEmoteSizeCheck(request.entry, code, msg.getResponseHeaders())
        queueSizeChecks()
        return
    end if

    body = msg.getString()
    json = invalid
    if code = 200 then json = ParseJson(body)
    count = 0
    if key = "history"
        addHistory(json)
        if json <> invalid and json.messages <> invalid then count = json.messages.Count()
    else if key = "badges"
        m.badges = parseTwitchBadges(json)
        count = m.badges.Count()
    else if key = "twitch-emotes"
        m.tokenizer.twitchAnimated = parseTwitchAnimatedEmotes(json)
        count = m.tokenizer.twitchAnimated.Count()
    else
        m.emoteLists[key] = parseChatEmotes(key, json)
        m.tokenizer.emotes = buildChatEmoteMap(m.sources, m.emoteLists)
        count = m.emoteLists[key].Count()
    end if
    elapsed = m.clock.TotalMilliseconds() - request.started
    ? getLogTimestamp(); " [ChatJob] "; key; ": HTTP "; code; ", "; body.Len(); " bytes, "; count; " items, "; elapsed; "ms";
    if code = 200 and json = invalid
        print " (JSON parse failed)"
    else if code <> 200
        print " ("; msg.getFailureReason(); ")"
    else
        print ""
    end if
end sub

' Puts recent-messages history ahead of anything already received live.
sub addHistory(json as dynamic)
    if json = invalid or json.messages = invalid then return
    history = []
    for each line in json.messages
        history.Push({ line: line })
    end for
    history.Append(m.inbox)
    m.inbox = history
end sub
