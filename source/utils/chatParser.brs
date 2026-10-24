' Twitch IRC parsing and message tokenizing for the chat overlay.
' Pure functions so they can run in the ChatJob task thread and be unit tested.

' Splits one raw IRC line into tags, sender, command, channel and trailing text.
' Returns invalid for lines that are not valid IRC.
function parseIrcLine(line as string) as object
    msg = { tags: {}, nick: "", command: "", channel: "", trailing: "" }
    rest = line
    if rest.Left(1) = "@"
        space = rest.Instr(" ")
        if space < 0 then return invalid
        msg.tags = parseIrcTags(rest.Mid(1, space - 1))
        rest = rest.Mid(space + 1)
    end if
    if rest.Left(1) = ":"
        space = rest.Instr(" ")
        if space < 0 then return invalid
        prefix = rest.Mid(1, space - 1)
        bang = prefix.Instr("!")
        if bang > 0
            msg.nick = prefix.Left(bang)
        end if
        rest = rest.Mid(space + 1)
    end if
    trailingAt = rest.Instr(" :")
    if trailingAt >= 0
        msg.trailing = rest.Mid(trailingAt + 2)
        rest = rest.Left(trailingAt)
    end if
    parts = rest.Split(" ")
    msg.command = parts[0]
    if parts.Count() > 1
        msg.channel = parts[1]
    end if
    return msg
end function

' Parses "key=value;key2=value2" IRC tags. Keys without a value map to "".
function parseIrcTags(raw as string) as object
    tags = {}
    for each pair in raw.Split(";")
        eq = pair.Instr("=")
        if eq > 0
            tags[pair.Left(eq)] = pair.Mid(eq + 1)
        else if pair <> ""
            tags[pair] = ""
        end if
    end for
    return tags
end function

' Reverses IRCv3 tag escaping (\s space, \: semicolon, \\ backslash, \r and \n).
function unescapeIrcTagValue(value as string) as string
    if value.Instr("\") < 0 then return value
    result = ""
    i = 0
    count = value.Len()
    while i < count
        ch = value.Mid(i, 1)
        if ch = "\" and i + 1 < count
            nextCh = value.Mid(i + 1, 1)
            if nextCh = "s"
                result = result + " "
            else if nextCh = ":"
                result = result + ";"
            else if nextCh = "\"
                result = result + "\"
            else if nextCh = "r" or nextCh = "n"
                result = result + " "
            else
                result = result + nextCh
            end if
            i = i + 2
        else
            if ch <> "\"
                result = result + ch
            end if
            i = i + 1
        end if
    end while
    return result
end function

' Maps each Twitch emote code in the message to its emote id using the IRC "emotes" tag
' ("id:start-end,start-end/id2:start-end"). Ranges that don't line up with a whole word
' are skipped so a bad offset can never swallow normal text.
function parseTwitchEmoteRanges(text as string, emotesTag as dynamic) as object
    names = {}
    names.SetModeCaseSensitive()
    if emotesTag = invalid or emotesTag = "" then return names
    textLen = text.Len()
    for each emote in emotesTag.Split("/")
        colon = emote.Instr(":")
        if colon > 0
            id = emote.Left(colon)
            for each range in emote.Mid(colon + 1).Split(",")
                dash = range.Instr("-")
                if dash > 0
                    first = range.Left(dash).ToInt()
                    last = range.Mid(dash + 1).ToInt()
                    if first >= 0 and last >= first and last < textLen
                        startsWord = true
                        if first > 0
                            startsWord = (text.Mid(first - 1, 1) = " ")
                        end if
                        endsWord = true
                        if last < textLen - 1
                            endsWord = (text.Mid(last + 1, 1) = " ")
                        end if
                        if startsWord and endsWord
                            names[text.Mid(first, last - first + 1)] = id
                        end if
                    end if
                end if
            end for
        end if
    end for
    return names
end function

' Builds the reusable lookup state for tokenizeChatMessage(). emotes is the case-sensitive
' name -> emote map from the third-party providers.
function createChatTokenizer(emotes as object) as object
    return {
        emotes: emotes,
        twitchAnimated: {}, ' ids of the channel's animated Twitch emotes
        pendingChecks: [], ' emote entries whose animated file still needs a size check
        ' Chatterino/7TV users append U+E0000 to dodge Twitch's duplicate-message check.
        dupeBypass: Chr(&hE0000),
        nonAscii: CreateObject("roRegex", "[^\x00-\x7F]", ""),
        presentation: emojiPresentationRanges(),
        textual: emojiTextualRanges()
    }
end function

' Splits a chat message into render tokens:
'   { text: "words joined by spaces", link?: true, glue?: true }
'   { url, w, h, anim?, zw?, unsized?, emoji?, glue? } for emotes and emoji
' glue means "no space before this token" (emoji touching text).
function tokenizeChatMessage(text as string, twitchEmotes as object, tokenizer as object) as object
    tokens = []
    textRun = ""
    emotes = tokenizer.emotes
    for each word in text.Replace(tokenizer.dupeBypass, "").Split(" ")
        if word <> ""
            image = invalid
            twitchId = twitchEmotes[word]
            if twitchId <> invalid
                image = { url: "https://static-cdn.jtvnw.net/emoticons/v2/" + twitchId + "/static/dark/2.0", w: 28, h: 28 }
                if tokenizer.twitchAnimated[twitchId] = true
                    ' Twitch only serves animated emotes as GIFs.
                    image.anim = lossyWebpUrl("https://static-cdn.jtvnw.net/emoticons/v2/" + twitchId + "/animated/dark/1.0")
                end if
            else
                image = emotes[word]
                if image <> invalid and image.check <> invalid
                    if image.checkQueued <> true
                        image.checkQueued = true
                        tokenizer.pendingChecks.Push(image)
                    end if
                    ' Animate while the size check runs (some BTTV stills are blank); once it
                    ' answers, only files small enough keep animating.
                    image = { url: image.url, w: image.w, h: image.h, unsized: image.unsized, zw: image.zw, anim: image.check }
                end if
            end if

            if image <> invalid
                if textRun <> ""
                    tokens.Push({ text: textRun })
                    textRun = ""
                end if
                tokens.Push(image)
            else if word.Left(7) = "http://" or word.Left(8) = "https://"
                if textRun <> ""
                    tokens.Push({ text: textRun })
                    textRun = ""
                end if
                tokens.Push({ text: word, link: true })
            else
                parts = splitEmoji(word, tokenizer)
                if parts = invalid
                    if textRun = ""
                        textRun = word
                    else
                        textRun = textRun + " " + word
                    end if
                else
                    if textRun <> ""
                        tokens.Push({ text: textRun })
                        textRun = ""
                    end if
                    tokens.Append(parts)
                end if
            end if
        end if
    end for
    if textRun <> ""
        tokens.Push({ text: textRun })
    end if
    return tokens
end function

' Splits a word that contains emoji into text and emoji tokens. Returns invalid when the
' word has no emoji so the caller can keep it in the current text run.
' Emoji are found by code point instead of a regex: the brs-engine simulator can't compile
' \x{...} patterns and crashes outside of try/catch.
function splitEmoji(word as string, tokenizer as object) as dynamic
    if not tokenizer.nonAscii.IsMatch(word) then return invalid
    chars = word.Len()
    points = []
    starts = [] ' string index of each code point (UTF-16 engines use two per emoji)
    i = 0
    while i < chars
        code = Asc(word.Mid(i, 1))
        starts.Push(i)
        if code >= &hD800 and code <= &hDBFF and i + 1 < chars
            low = Asc(word.Mid(i + 1, 1))
            if low >= &hDC00 and low <= &hDFFF
                code = &h10000 + ((code - &hD800) << 10) + (low - &hDC00)
                i = i + 1
            end if
        end if
        points.Push(code)
        i = i + 1
    end while
    starts.Push(chars)

    parts = []
    textStart = 0
    p = 0
    while p < points.Count()
        last = emojiSequenceEnd(points, p, tokenizer)
        if last > p
            if starts[p] > textStart
                parts.Push({ text: word.Mid(textStart, starts[p] - textStart), glue: parts.Count() > 0 })
            end if
            parts.Push({ url: twemojiUrl(points, p, last), w: 72, h: 72, emoji: true, glue: parts.Count() > 0 })
            textStart = starts[last]
            p = last
        else
            p = p + 1
        end if
    end while
    if parts.Count() = 0 then return invalid
    if textStart < chars
        parts.Push({ text: word.Mid(textStart), glue: true })
    end if
    return parts
end function

' Index just past the emoji sequence that starts at points[p], or p when none starts there.
' Covers flags, keycaps, skin tones, subdivision flags and zero-width-joiner sequences.
function emojiSequenceEnd(points as object, p as integer, tokenizer as object) as integer
    count = points.Count()
    cp = points[p]
    nextCp = 0
    if p + 1 < count then nextCp = points[p + 1]
    if cp >= &h1F1E6 and cp <= &h1F1FF
        if nextCp >= &h1F1E6 and nextCp <= &h1F1FF then return p + 2
        return p
    end if
    if cp = 35 or cp = 42 or (cp >= 48 and cp <= 57)
        q = p + 1
        if q < count and points[q] = &hFE0F then q = q + 1
        if q < count and points[q] = &h20E3 then return q + 1
        return p
    end if
    ' Text-style symbols like U+2764 are only emoji when followed by U+FE0F.
    isEmoji = inCodeRanges(cp, tokenizer.presentation)
    if not isEmoji and nextCp = &hFE0F then isEmoji = inCodeRanges(cp, tokenizer.textual)
    if not isEmoji then return p
    q = emojiModifiersEnd(points, p + 1)
    while q + 1 < count and points[q] = &h200D
        joined = points[q + 1]
        if not inCodeRanges(joined, tokenizer.presentation) and not inCodeRanges(joined, tokenizer.textual) then exit while
        q = emojiModifiersEnd(points, q + 2)
    end while
    return q
end function

' Skips the variation selector, skin tone and tag characters that belong to an emoji.
function emojiModifiersEnd(points as object, q as integer) as integer
    count = points.Count()
    if q < count and points[q] = &hFE0F then q = q + 1
    if q < count and points[q] >= &h1F3FB and points[q] <= &h1F3FF then q = q + 1
    while q < count and points[q] >= &hE0020 and points[q] <= &hE007F
        q = q + 1
    end while
    return q
end function

function inCodeRanges(cp as integer, ranges as object) as boolean
    for each range in ranges
        if cp < range[0] then return false
        if cp <= range[1] then return true
    end for
    return false
end function

' Twemoji asset URL for points[first..last): code points in hex, U+FE0F dropped unless the
' sequence has a zero-width joiner (the same rule Twemoji uses).
function twemojiUrl(points as object, first as integer, last as integer) as string
    hasJoiner = false
    for i = first to last - 1
        if points[i] = &h200D then hasJoiner = true
    end for
    names = []
    for i = first to last - 1
        if hasJoiner or points[i] <> &hFE0F then names.Push(LCase(StrI(points[i], 16)))
    end for
    return "https://cdn.jsdelivr.net/gh/jdecked/twemoji@15.1.0/assets/72x72/" + names.Join("-") + ".png"
end function

' Returns a 0xRRGGBBFF name color that stays readable on the dark chat background.
' Users without a color get one of Twitch's defaults picked from their login.
function chatNameColor(hexColor as dynamic, login as string) as string
    if hexColor = invalid or hexColor.Len() <> 7 or hexColor.Left(1) <> "#"
        palette = ["#FF0000", "#0000FF", "#008000", "#B22222", "#FF7F50", "#9ACD32", "#FF4500", "#2E8B57", "#DAA520", "#D2691E", "#5F9EA0", "#1E90FF", "#FF69B4", "#8A2BE2", "#00FF7F"]
        sum = 0
        for i = 0 to login.Len() - 1
            sum = sum + Asc(login.Mid(i, 1))
        end for
        hexColor = palette[sum mod palette.Count()]
    end if
    r = Val(hexColor.Mid(1, 2), 16)
    g = Val(hexColor.Mid(3, 2), 16)
    b = Val(hexColor.Mid(5, 2), 16)
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    minLuma = 120
    if luma < minLuma
        lift = (minLuma - luma) / (255 - luma)
        r = r + (255 - r) * lift
        g = g + (255 - g) * lift
        b = b + (255 - b) * lift
    end if
    return "0x" + hexByte(r) + hexByte(g) + hexByte(b) + "FF"
end function

function hexByte(value as float) as string
    n = Int(value + 0.5)
    if n > 255 then n = 255
    if n < 0 then n = 0
    return Right("0" + StrI(n, 16), 2)
end function

' Emoji_Presentation code points from Unicode 15.1 emoji-data.txt, the version Twemoji 15.1
' covers. Regional indicators are left out because flags are matched as pairs.
function emojiPresentationRanges() as object
    return [
        [&h231A, &h231B], [&h23E9, &h23EC], [&h23F0, &h23F0], [&h23F3, &h23F3], [&h25FD, &h25FE], [&h2614, &h2615],
        [&h2648, &h2653], [&h267F, &h267F], [&h2693, &h2693], [&h26A1, &h26A1], [&h26AA, &h26AB], [&h26BD, &h26BE],
        [&h26C4, &h26C5], [&h26CE, &h26CE], [&h26D4, &h26D4], [&h26EA, &h26EA], [&h26F2, &h26F3], [&h26F5, &h26F5],
        [&h26FA, &h26FA], [&h26FD, &h26FD], [&h2705, &h2705], [&h270A, &h270B], [&h2728, &h2728], [&h274C, &h274C],
        [&h274E, &h274E], [&h2753, &h2755], [&h2757, &h2757], [&h2795, &h2797], [&h27B0, &h27B0], [&h27BF, &h27BF],
        [&h2B1B, &h2B1C], [&h2B50, &h2B50], [&h2B55, &h2B55], [&h1F004, &h1F004], [&h1F0CF, &h1F0CF], [&h1F18E, &h1F18E],
        [&h1F191, &h1F19A], [&h1F201, &h1F201], [&h1F21A, &h1F21A], [&h1F22F, &h1F22F], [&h1F232, &h1F236], [&h1F238, &h1F23A],
        [&h1F250, &h1F251], [&h1F300, &h1F320], [&h1F32D, &h1F335], [&h1F337, &h1F37C], [&h1F37E, &h1F393], [&h1F3A0, &h1F3CA],
        [&h1F3CF, &h1F3D3], [&h1F3E0, &h1F3F0], [&h1F3F4, &h1F3F4], [&h1F3F8, &h1F43E], [&h1F440, &h1F440], [&h1F442, &h1F4FC],
        [&h1F4FF, &h1F53D], [&h1F54B, &h1F54E], [&h1F550, &h1F567], [&h1F57A, &h1F57A], [&h1F595, &h1F596], [&h1F5A4, &h1F5A4],
        [&h1F5FB, &h1F64F], [&h1F680, &h1F6C5], [&h1F6CC, &h1F6CC], [&h1F6D0, &h1F6D2], [&h1F6D5, &h1F6D7], [&h1F6DC, &h1F6DF],
        [&h1F6EB, &h1F6EC], [&h1F6F4, &h1F6FC], [&h1F7E0, &h1F7EB], [&h1F7F0, &h1F7F0], [&h1F90C, &h1F93A], [&h1F93C, &h1F945],
        [&h1F947, &h1F9FF], [&h1FA70, &h1FA7C], [&h1FA80, &h1FA88], [&h1FA90, &h1FABD], [&h1FABF, &h1FAC5], [&h1FACE, &h1FADB],
        [&h1FAE0, &h1FAE8], [&h1FAF0, &h1FAF8]
    ]
end function

' Emoji that default to text style (Emoji minus Emoji_Presentation, without the ASCII
' keycap bases), same source as above.
function emojiTextualRanges() as object
    return [
        [&hA9, &hA9], [&hAE, &hAE], [&h203C, &h203C], [&h2049, &h2049], [&h2122, &h2122], [&h2139, &h2139],
        [&h2194, &h2199], [&h21A9, &h21AA], [&h2328, &h2328], [&h23CF, &h23CF], [&h23ED, &h23EF], [&h23F1, &h23F2],
        [&h23F8, &h23FA], [&h24C2, &h24C2], [&h25AA, &h25AB], [&h25B6, &h25B6], [&h25C0, &h25C0], [&h25FB, &h25FC],
        [&h2600, &h2604], [&h260E, &h260E], [&h2611, &h2611], [&h2618, &h2618], [&h261D, &h261D], [&h2620, &h2620],
        [&h2622, &h2623], [&h2626, &h2626], [&h262A, &h262A], [&h262E, &h262F], [&h2638, &h263A], [&h2640, &h2640],
        [&h2642, &h2642], [&h265F, &h2660], [&h2663, &h2663], [&h2665, &h2666], [&h2668, &h2668], [&h267B, &h267B],
        [&h267E, &h267E], [&h2692, &h2692], [&h2694, &h2697], [&h2699, &h2699], [&h269B, &h269C], [&h26A0, &h26A0],
        [&h26A7, &h26A7], [&h26B0, &h26B1], [&h26C8, &h26C8], [&h26CF, &h26CF], [&h26D1, &h26D1], [&h26D3, &h26D3],
        [&h26E9, &h26E9], [&h26F0, &h26F1], [&h26F4, &h26F4], [&h26F7, &h26F9], [&h2702, &h2702], [&h2708, &h2709],
        [&h270C, &h270D], [&h270F, &h270F], [&h2712, &h2712], [&h2714, &h2714], [&h2716, &h2716], [&h271D, &h271D],
        [&h2721, &h2721], [&h2733, &h2734], [&h2744, &h2744], [&h2747, &h2747], [&h2763, &h2764], [&h27A1, &h27A1],
        [&h2934, &h2935], [&h2B05, &h2B07], [&h3030, &h3030], [&h303D, &h303D], [&h3297, &h3297], [&h3299, &h3299],
        [&h1F170, &h1F171], [&h1F17E, &h1F17F], [&h1F202, &h1F202], [&h1F237, &h1F237], [&h1F321, &h1F321], [&h1F324, &h1F32C],
        [&h1F336, &h1F336], [&h1F37D, &h1F37D], [&h1F396, &h1F397], [&h1F399, &h1F39B], [&h1F39E, &h1F39F], [&h1F3CB, &h1F3CE],
        [&h1F3D4, &h1F3DF], [&h1F3F3, &h1F3F3], [&h1F3F5, &h1F3F5], [&h1F3F7, &h1F3F7], [&h1F43F, &h1F43F], [&h1F441, &h1F441],
        [&h1F4FD, &h1F4FD], [&h1F549, &h1F54A], [&h1F56F, &h1F570], [&h1F573, &h1F579], [&h1F587, &h1F587], [&h1F58A, &h1F58D],
        [&h1F590, &h1F590], [&h1F5A5, &h1F5A5], [&h1F5A8, &h1F5A8], [&h1F5B1, &h1F5B2], [&h1F5BC, &h1F5BC], [&h1F5C2, &h1F5C4],
        [&h1F5D1, &h1F5D3], [&h1F5DC, &h1F5DE], [&h1F5E1, &h1F5E1], [&h1F5E3, &h1F5E3], [&h1F5E8, &h1F5E8], [&h1F5EF, &h1F5EF],
        [&h1F5F3, &h1F5F3], [&h1F5FA, &h1F5FA], [&h1F6CB, &h1F6CB], [&h1F6CD, &h1F6CF], [&h1F6E0, &h1F6E5], [&h1F6E9, &h1F6E9],
        [&h1F6F0, &h1F6F0], [&h1F6F3, &h1F6F3]
    ]
end function