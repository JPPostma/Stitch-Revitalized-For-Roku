' Chat overlay. ChatJob does all network and parsing work in its own thread; this component
' only lays out the ready-to-draw batches it receives (badges, name, text, emotes, emoji).

sub init()
    m.background = m.top.findNode("chatBackground")
    m.panel = m.top.findNode("chatPanel")
    m.content = m.top.findNode("chatContent")

    m.textColor = "0xEFEFF1FF"
    m.mutedColor = "0xADADB8FF"
    m.linkColor = "0xBF94FFFF"
    m.noticeColor = "0x9147FFFF"
    m.noticeBackground = "0x9147FF26"
    m.regularFont = "pkg:/fonts/Archivo-Regular.otf"
    m.boldFont = "pkg:/fonts/Archivo-Bold.otf"

    m.chatJob = invalid
    m.rows = [] ' drawn messages, oldest first: { node, y, h, id, login, anims }
    m.recent = [] ' last messages' data, used to redraw after resizing or re-showing chat
    m.animated = [] ' playing AnimatedImage entries, oldest first
    m.paused = [] ' AnimatedImage entries paused on their current frame, oldest first
    m.contentBottom = 0
    m.emoteSizes = {}
    m.emoteSizes.SetModeCaseSensitive()
    ' AnimatedImage needs Roku OS 15.3+ and isn't available on some older models.
    ' BrighterScript's component list doesn't know it yet, hence the disable comment.
    ' bs:disable-next-line: 1128
    m.canAnimate = CreateObject("roSGNode", "AnimatedImage") <> invalid
    m.animLimit = 0
    m.clock = CreateObject("roTimespan")
    m.animById = {} ' AnimatedImage id -> its entry, to react to state changes
    m.animSeq = 0
    resetAnimationHealth()
    m.stillFailed = 0
    m.animWatch = CreateObject("roSGNode", "Timer")
    m.animWatch.duration = 2
    m.animWatch.repeat = true
    m.animWatch.observeField("fire", "checkAnimations")
    m.syncMode = "auto"
    m.latencySamples = []
    m.chatDelayMs = 0

    m.top.observeField("visible", "onVisibleChange")
    applyLayout()
end sub

sub onEnterChannel()
    stopJobs()
    m.recent = []
    clearRows()
    if m.top.channel = "" then return

    m.animLimit = 0
    if m.canAnimate then m.animLimit = settingNumber("ChatAnimatedEmotes", "16")
    m.chatJob = CreateObject("roSGNode", "ChatJob")
    m.chatJob.channel = m.top.channel
    m.chatJob.channelId = m.top.channel_id
    m.syncMode = get_user_setting("ChatSync", "auto")
    m.latencySamples = []
    if m.syncMode = "auto"
        ' Typical distance behind live on Roku, used until the player reports the real one.
        m.chatDelayMs = 20000
    else
        m.chatDelayMs = m.syncMode.ToInt() * 1000
    end if
    m.chatJob.delayMs = m.chatDelayMs
    m.chatJob.history = get_user_setting("ChatHistory", "true") = "true"
    m.chatJob.providers = {
        seventv: get_user_setting("7tvEmote", "true") = "true",
        bttv: get_user_setting("BetterTTVEmote", "true") = "true",
        ffz: get_user_setting("FFZEmote", "true") = "true"
    }
    m.chatJob.observeField("messages", "onChatMessages")
    m.chatJob.control = "run"
    resetAnimationHealth()
    if m.animLimit > 0 then m.animWatch.control = "start"
    ? getLogTimestamp(); " [Chat] "; m.top.channel; ": AnimatedImage available="; m.canAnimate; " limit="; m.animLimit; " sync="; m.syncMode
end sub

' Chat Sync "auto": the live player reports how far behind the live edge it is (ms) on every
' new segment. Chat is delayed by the median of the last few readings, so it lines up with
' the picture (and follows it after a rebuffer) without jumping on every segment.
sub onVideoLatency()
    latency = m.top.videoLatency
    if latency < 0 or m.syncMode <> "auto" then return
    m.latencySamples.Push(latency)
    if m.latencySamples.Count() > 5 then m.latencySamples.Shift()
    median = medianOf(m.latencySamples)
    if Abs(median - m.chatDelayMs) < 1000 then return
    m.chatDelayMs = median
    if m.chatJob <> invalid then m.chatJob.delayMs = median
end sub

' Middle value of a short list (the upper one for an even count), found by counting rather
' than roArray.Sort(), which the brs-engine simulator leaves unsorted. Index loops, because
' nested "for each" over one array shares its enumerator.
function medianOf(values as object) as integer
    count = values.Count()
    for i = 0 to count - 1
        below = 0
        above = 0
        for j = 0 to count - 1
            if values[j] < values[i] then below = below + 1
            if values[j] > values[i] then above = above + 1
        end for
        if below <= count \ 2 and above <= (count - 1) \ 2 then return values[i]
    end for
    return values[0]
end function

' Stops the ChatJob task (IRC socket and downloads). Called from VideoPlayer.exitPlayer()
' so the connection closes at user-initiated exit, not only when onDestroy eventually runs.
sub stopJobs()
    m.chatJob = destroyTask(m.chatJob, "messages")
    if m.animWatch <> invalid then m.animWatch.control = "stop"
end sub

function settingNumber(name as string, fallback as string) as integer
    value = get_user_setting(name, fallback)
    if value = invalid then value = fallback
    return value.ToInt()
end function

sub applyLayout()
    if m.content = invalid then return
    width = m.top.width
    height = m.top.height
    m.fontSize = m.top.fontSize
    if m.fontSize < 8 then m.fontSize = 14

    m.padX = 8
    m.right = width - m.padX
    m.measureRegular = createText("", m.regularFont, m.textColor)
    m.measureBold = createText("", m.boldFont, m.textColor)
    m.widthCache = {}
    m.widthCache.SetModeCaseSensitive()
    m.boldWidthCache = {}
    m.boldWidthCache.SetModeCaseSensitive()
    m.cachedWidths = 0

    m.lineH = measureHeight("Ag")
    m.spaceW = measureText("a a", false) - measureText("aa", false)
    if m.spaceW <= 0 then m.spaceW = m.fontSize * 0.3
    m.emoteH = Int(m.fontSize * 1.8 + 0.5)
    m.badgeH = Int(m.fontSize * 1.3 + 0.5)
    m.emojiH = Int(m.fontSize * 1.3 + 0.5)
    m.lineGap = 2
    m.rowGap = Int(m.fontSize * 0.5 + 0.5)
    m.maxRows = Int(height / (m.lineH + m.rowGap)) + 2

    m.background.width = width
    m.background.height = height
    m.panel.clippingRect = [0, 0, width, height]
    redraw()
end sub

sub onVisibleChange()
    if m.top.visible
        redraw()
    else
        clearRows() ' frees nodes and stops animations while chat is hidden
    end if
end sub

sub onChatMessages(event as object)
    batch = event.getData()
    if batch = invalid then return
    ' During a flood only the newest rows that fit on screen are worth drawing.
    firstToDraw = 0
    shown = 0
    for i = batch.Count() - 1 to 0 step -1
        kind = batch[i].kind
        if kind <> "clear" and kind <> "delete"
            shown = shown + 1
            if shown > m.maxRows
                firstToDraw = i + 1
                exit for
            end if
        end if
    end for

    visible = m.top.visible
    for i = 0 to batch.Count() - 1
        item = batch[i]
        if item.kind = "clear"
            clearMessages(item.login)
        else if item.kind = "delete"
            deleteMessage(item.id)
        else
            remember(item)
            if visible and i >= firstToDraw then drawRow(item)
        end if
    end for
end sub

sub remember(item as object)
    m.recent.Push(item)
    if m.recent.Count() > 100 then m.recent.Shift()
end sub

' CLEARCHAT: dims a timed-out/banned user's messages, or wipes chat when login is "".
sub clearMessages(login as string)
    if login = ""
        m.recent = []
        clearRows()
        item = { kind: "system", text: "Chat was cleared by a moderator.", id: "", login: "" }
        remember(item)
        if m.top.visible then drawRow(item)
        return
    end if
    for each item in m.recent
        if item.login = login then item.deleted = true
    end for
    for each row in m.rows
        if row.login = login then row.node.opacity = 0.35
    end for
end sub

' CLEARMSG: dims a single deleted message.
sub deleteMessage(id as string)
    for each item in m.recent
        if item.id = id then item.deleted = true
    end for
    for each row in m.rows
        if row.id = id then row.node.opacity = 0.35
    end for
end sub

sub redraw()
    clearRows()
    if not m.top.visible then return
    first = m.recent.Count() - m.maxRows
    if first < 0 then first = 0
    for i = first to m.recent.Count() - 1
        drawRow(m.recent[i])
    end for
end sub

sub clearRows()
    m.content.removeChildrenIndex(m.content.getChildCount(), 0)
    m.rows = []
    m.animated = []
    m.paused = []
    m.animById = {}
    m.contentBottom = 0
    m.content.translation = [0, m.top.height]
end sub

' Appends a message below the others and scrolls by moving the content group, so older
' rows never need repositioning.
sub drawRow(item as object)
    row = buildRow(item)
    row.y = m.contentBottom
    row.node.translation = [0, row.y]
    m.content.appendChild(row.node)
    m.contentBottom = m.contentBottom + row.h
    m.rows.Push(row)
    trackAnimations(row.anims)
    pruneRows()
    m.content.translation = [0, m.top.height - m.contentBottom]
end sub

sub pruneRows()
    visibleTop = m.contentBottom - m.top.height
    while m.rows.Count() > 0
        row = m.rows[0]
        if row.y + row.h > visibleTop and m.rows.Count() <= m.maxRows * 2 then exit while
        m.rows.Shift()
        m.content.removeChild(row.node)
        releaseAnimations(row.anims)
    end while
    ' Keep coordinates small during long sessions.
    if m.rows.Count() > 0 and m.rows[0].y > 100000
        offset = m.rows[0].y
        for each row in m.rows
            row.y = row.y - offset
            row.node.translation = [0, row.y]
        end for
        m.contentBottom = m.contentBottom - offset
    end if
end sub

' Keeps at most animLimit emotes animating. Older ones pause on their current frame (provider
' stills are just the first frame, which is blank for some emotes); only the oldest paused
' ones, beyond twice the limit, are swapped for still images to free the decoders.
sub trackAnimations(anims as object)
    for each entry in anims
        m.animated.Push(entry)
    end for
    while m.animated.Count() > m.animLimit
        entry = m.animated.Shift()
        entry.node.control = "pause"
        m.paused.Push(entry)
    end while
    while m.paused.Count() > m.animLimit * 2
        freezeAnimation(m.paused.Shift())
    end while
end sub

sub freezeAnimation(entry as object)
    if entry.dead then return
    entry.dead = true
    animatedNode = entry.node
    animatedNode.unobserveField("state")
    m.animById.Delete(animatedNode.id)
    poster = CreateObject("roSGNode", "Poster")
    poster.loadDisplayMode = "scaleToFit"
    poster.width = animatedNode.width
    poster.height = animatedNode.height
    poster.translation = animatedNode.translation
    poster.uri = entry.still
    entry.parent.replaceChild(poster, entry.index)
end sub

sub releaseAnimations(anims as object)
    if anims.Count() = 0 then return
    for each entry in anims
        entry.dead = true
        entry.node.unobserveField("state")
        m.animById.Delete(entry.node.id)
    end for
    m.animated = liveAnimations(m.animated)
    m.paused = liveAnimations(m.paused)
end sub

' AnimatedImage goes downloading -> init -> first -> decode when it works, or to error.
sub onAnimatedState(event as object)
    node = event.getRoSGNode()
    entry = m.animById[node.id]
    if entry = invalid or entry.dead then return
    updateAnimationState(entry, event.getData())
end sub

sub updateAnimationState(entry as object, state as string)
    if state = "first" or state = "decode"
        if not entry.started
            entry.started = true
            way = animWay(entry.node.uri)
            way.started = way.started + 1
            if way.started = 1 then ? getLogTimestamp(); " [Chat] animated emotes are playing ("; entry.node.uri; ")"
        end if
        entry.node.unobserveField("state")
    else if state = "error"
        failAnimation(entry, "error: " + entry.node.error)
    end if
end sub

' Swaps animated emotes that never start (stuck downloading) for their still image, so an
' emote is never left blank. Reads the state directly as well, in case a state change
' wasn't reported.
sub checkAnimations()
    now = m.clock.TotalMilliseconds()
    for each list in [m.animated, m.paused]
        for each entry in list
            if not entry.dead and not entry.started
                updateAnimationState(entry, entry.node.state)
                if not entry.dead and not entry.started and now - entry.created > 8000
                    failAnimation(entry, "stuck in state " + entry.node.state)
                end if
            end if
        end for
    end for
end sub

' Draws a failed animation still. From then on that emote uses its re-encoded copy (some
' 7TV files have lossless frames), or its still image if the re-encoded copy is what failed.
sub failAnimation(entry as object, reason as string)
    uri = entry.node.uri
    way = animWay(uri)
    way.failed = way.failed + 1
    m.animFailed = m.animFailed + 1
    if m.animFailed <= 8 then ? getLogTimestamp(); " [Chat] animated emote fell back to its still image ("; reason; "): "; uri
    if isLossyWebpUrl(uri)
        m.animSwap[entry.anim] = ""
    else
        m.animSwap[entry.anim] = lossyWebpUrl(uri)
    end if
    freezeAnimation(entry)
    m.animated = liveAnimations(m.animated)
    m.paused = liveAnimations(m.paused)
    if way.started = 0 and way.failed = 4
        if isLossyWebpUrl(uri)
            ? getLogTimestamp(); " [Chat] re-encoded animated emotes are not playing; drawing them still"
        else
            ? getLogTimestamp(); " [Chat] animated emotes are not playing straight from the provider; using re-encoded copies"
        end if
    end if
end sub

' Animations play two ways: straight from the provider (7TV) or re-encoded by wsrv.nl (BTTV,
' Twitch, and 7TV files that didn't play). A way whose first few files all fail is given
' up for the stream, so one broken way doesn't turn off the other.
sub resetAnimationHealth()
    m.animDirect = { started: 0, failed: 0 }
    m.animProxied = { started: 0, failed: 0 }
    m.animFailed = 0
    m.animSwap = {} ' animated URL -> the file to use instead: its re-encoded copy, or "" (still)
    m.animSwap.SetModeCaseSensitive()
end sub

function animWay(uri as string) as object
    if isLossyWebpUrl(uri) then return m.animProxied
    return m.animDirect
end function

function animWayWorks(way as object) as boolean
    return way.started > 0 or way.failed < 4
end function

' The animated file to draw for an emote, or "" for its still image.
function pickAnimation(anim as string) as string
    swap = m.animSwap[anim]
    if swap <> invalid then anim = swap
    if anim <> "" and not isLossyWebpUrl(anim) and not animWayWorks(m.animDirect) then anim = lossyWebpUrl(anim)
    if anim <> "" and isLossyWebpUrl(anim) and not animWayWorks(m.animProxied) then anim = ""
    return anim
end function

function liveAnimations(entries as object) as object
    live = []
    for each entry in entries
        if not entry.dead then live.Push(entry)
    end for
    return live
end function

' Lays out one message: [badges] Name: text emote text... wrapped to the panel width.
function buildRow(item as object) as object
    group = CreateObject("roSGNode", "Group")
    layout = {
        group: group,
        x: m.padX,
        indent: m.padX,
        top: 0,
        lineH: m.lineH,
        items: [],
        first: true,
        run: "",
        runX: 0,
        runColor: "",
        lastEmote: invalid,
        anims: []
    }

    highlight = invalid
    accent = invalid
    if item.kind = "notice"
        ' Created first so the indexes recorded for animated emotes stay valid.
        highlight = CreateObject("roSGNode", "Rectangle")
        highlight.color = m.noticeBackground
        group.appendChild(highlight)
        accent = CreateObject("roSGNode", "Rectangle")
        accent.color = m.noticeColor
        group.appendChild(accent)
        layout.indent = m.padX + 4
        layout.x = layout.indent
        if item.notice <> ""
            layoutText(layout, item.notice, m.mutedColor, false)
            if item.tokens.Count() > 0 then newLine(layout)
        end if
    end if

    if item.kind = "system"
        layoutText(layout, item.text, m.mutedColor, false)
    else if item.tokens.Count() > 0
        layoutSender(layout, item)
        textColor = m.textColor
        if item.action then textColor = item.color
        for each token in item.tokens
            if token.text <> invalid
                color = textColor
                if token.link = true then color = m.linkColor
                layoutText(layout, token.text, color, token.glue = true)
            else
                layoutImage(layout, token)
            end if
        end for
    end if
    finishLine(layout)

    height = layout.top + layout.lineH
    if highlight <> invalid
        highlight.width = m.top.width
        highlight.height = height + m.rowGap
        highlight.translation = [0, 0 - m.rowGap / 2]
        accent.width = 3
        accent.height = height + m.rowGap
        accent.translation = [0, 0 - m.rowGap / 2]
    end if
    if item.deleted = true then group.opacity = 0.35
    return { node: group, h: height + m.rowGap, id: item.id, login: item.login, anims: layout.anims }
end function

sub layoutSender(layout as object, item as object)
    for each url in item.badges
        badge = CreateObject("roSGNode", "Poster")
        badge.loadDisplayMode = "scaleToFit"
        badge.width = m.badgeH
        badge.height = m.badgeH
        badge.uri = url
        addNode(layout, badge, m.badgeH, m.badgeH, 3)
    end for
    name = item.name
    if not item.action then name = name + ":"
    label = createText(name, m.boldFont, item.color)
    addNode(layout, label, wordWidth(name, true), m.lineH, 4)
end sub

sub layoutText(layout as object, text as string, color as string, glue as boolean)
    for each word in text.Split(" ")
        if word <> ""
            addWord(layout, word, color, glue)
            glue = false
        end if
    end for
end sub

' Adds a word to the current text run (one label per run of same-colored words on a line).
sub addWord(layout as object, word as string, color as string, glue as boolean)
    w = wordWidth(word, false)
    gap = m.spaceW
    if layout.first or glue then gap = 0
    if not layout.first and layout.x + gap + w > m.right
        newLine(layout)
        gap = 0
    end if
    if layout.x + gap + w > m.right
        breakWord(layout, word, color) ' wider than a whole line (long links, spam)
        return
    end if
    if layout.run <> "" and layout.runColor = color
        if gap > 0
            layout.run = layout.run + " " + word
        else
            layout.run = layout.run + word
        end if
    else
        flushRun(layout)
        layout.run = word
        layout.runX = layout.x + gap
        layout.runColor = color
    end if
    layout.x = layout.x + gap + w
    layout.first = false
    layout.lastEmote = invalid
end sub

sub breakWord(layout as object, word as string, color as string)
    flushRun(layout)
    rest = word
    while rest <> ""
        count = fitChars(rest, m.right - layout.x)
        piece = rest.Left(count)
        label = createText(piece, m.regularFont, color)
        layout.group.appendChild(label)
        layout.items.Push({ node: label, x: layout.x, h: m.lineH })
        layout.x = layout.x + measureText(piece, false)
        layout.first = false
        rest = rest.Mid(count)
        if rest <> "" then newLine(layout)
    end while
    layout.lastEmote = invalid
end sub

' Longest prefix of text (at least one character) that fits in width.
function fitChars(text as string, width as float) as integer
    low = 1
    high = text.Len()
    while low < high
        middle = (low + high + 1) \ 2
        if measureText(text.Left(middle), false) <= width
            low = middle
        else
            high = middle - 1
        end if
    end while
    return low
end function

sub layoutImage(layout as object, token as object)
    h = m.emoteH
    if token.emoji = true then h = m.emojiH
    sourceW = token.w
    sourceH = token.h
    if token.unsized = true
        size = m.emoteSizes[token.url]
        if size <> invalid
            sourceW = size.w
            sourceH = size.h
        end if
    end if
    w = h
    if sourceW > 0 and sourceH > 0 then w = Int(sourceW * h / sourceH + 0.5)

    node = createEmote(token, w, h)
    base = layout.lastEmote
    if token.zw = true and base <> invalid
        ' Zero-width emotes (hats, rain, steering wheels...) sit centered on the previous emote.
        layout.group.appendChild(node)
        layout.items.Push({ node: node, x: base.x + (base.w - w) / 2, h: h })
        if h > layout.lineH then layout.lineH = h
    else
        gap = m.spaceW
        if token.glue = true then gap = 0
        x = addNode(layout, node, w, h, gap)
        layout.lastEmote = { x: x, w: w }
    end if
    if node.subtype() = "AnimatedImage"
        entry = { node: node, parent: layout.group, index: layout.group.getChildCount() - 1, still: token.url, anim: token.anim, dead: false, started: false, created: m.clock.TotalMilliseconds() }
        layout.anims.Push(entry)
        m.animById[node.id] = entry
    end if
end sub

function createEmote(token as object, w as float, h as float) as object
    anim = ""
    if token.anim <> invalid and m.animLimit > 0 then anim = pickAnimation(token.anim)
    if anim <> ""
        ' bs:disable-next-line: 1128
        animated = CreateObject("roSGNode", "AnimatedImage")
        if animated <> invalid
            m.animSeq = m.animSeq + 1
            animated.id = "anim" + m.animSeq.ToStr()
            animated.observeField("state", "onAnimatedState")
            animated.width = w
            animated.height = h
            animated.loadingBitmapUri = token.url
            animated.failedBitmapUri = token.url
            animated.mimeType = "video/webp"
            animated.uri = anim
            animated.control = "loop"
            return animated
        end if
    end if
    poster = CreateObject("roSGNode", "Poster")
    poster.loadDisplayMode = "scaleToFit"
    poster.width = w
    poster.height = h
    poster.observeField("loadStatus", "onEmoteLoaded")
    poster.uri = token.url
    return poster
end function

' Learns the real size of emotes whose provider doesn't report one (BTTV) so later
' messages draw them at the right aspect ratio, and logs images that fail to load.
sub onEmoteLoaded(event as object)
    poster = event.getRoSGNode()
    status = event.getData()
    if status = "ready" and poster.bitmapHeight > 0
        m.emoteSizes[poster.uri] = { w: poster.bitmapWidth, h: poster.bitmapHeight }
    else if status = "failed"
        m.stillFailed = m.stillFailed + 1
        if m.stillFailed <= 5 then ? getLogTimestamp(); " [Chat] emote image failed to load: "; poster.uri
    end if
    if status = "ready" or status = "failed"
        poster.unobserveField("loadStatus")
    end if
end sub

' Places a fixed-size node on the current line, wrapping first if it doesn't fit.
' Returns the x it was placed at.
function addNode(layout as object, node as object, w as float, h as float, gap as float) as float
    flushRun(layout)
    if layout.first then gap = 0
    if not layout.first and layout.x + gap + w > m.right
        newLine(layout)
        gap = 0
    end if
    x = layout.x + gap
    layout.group.appendChild(node)
    layout.items.Push({ node: node, x: x, h: h })
    layout.x = x + w
    if h > layout.lineH then layout.lineH = h
    layout.first = false
    layout.lastEmote = invalid
    return x
end function

sub flushRun(layout as object)
    if layout.run = "" then return
    label = createText(layout.run, m.regularFont, layout.runColor)
    layout.group.appendChild(label)
    layout.items.Push({ node: label, x: layout.runX, h: m.lineH })
    layout.run = ""
end sub

sub newLine(layout as object)
    finishLine(layout)
    layout.top = layout.top + layout.lineH + m.lineGap
    layout.lineH = m.lineH
    layout.items = []
    layout.x = layout.indent
    layout.first = true
    layout.lastEmote = invalid
end sub

' Vertically centers everything placed on the current line.
sub finishLine(layout as object)
    flushRun(layout)
    for each placed in layout.items
        placed.node.translation = [placed.x, layout.top + (layout.lineH - placed.h) / 2]
    end for
end sub

function createText(text as string, font as string, color as string) as object
    label = CreateObject("roSGNode", "SimpleLabel")
    label.fontUri = font
    label.fontSize = m.fontSize
    label.color = color
    label.text = text
    return label
end function

function measureText(text as string, bold as boolean) as float
    label = m.measureRegular
    if bold then label = m.measureBold
    label.text = text
    width = 0
    try
        width = label.localBoundingRect().width
    catch e
        width = text.Len() * m.fontSize * 0.55
    end try
    return width
end function

function measureHeight(text as string) as float
    m.measureRegular.text = text
    height = 0
    try
        height = m.measureRegular.localBoundingRect().height
    catch e
        height = 0
    end try
    if height <= 0 then height = m.fontSize * 1.3
    return height
end function

' Word widths repeat constantly in chat (names, emote codes, "LUL"), so cache them.
function wordWidth(word as string, bold as boolean) as float
    cache = m.widthCache
    if bold then cache = m.boldWidthCache
    width = cache[word]
    if width = invalid
        if m.cachedWidths > 4000
            m.widthCache.Clear()
            m.boldWidthCache.Clear()
            m.cachedWidths = 0
        end if
        width = measureText(word, bold)
        cache[word] = width
        m.cachedWidths = m.cachedWidths + 1
    end if
    return width
end function

sub onDestroy()
    stopJobs()
    m.animWatch.unobserveField("fire")
    m.top.unobserveField("visible")
end sub
