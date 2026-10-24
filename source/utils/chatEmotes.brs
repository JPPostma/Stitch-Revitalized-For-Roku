' Third-party emote (7TV, BTTV, FFZ) and Twitch badge sources for the chat overlay.
' Every emote parser returns a flat list of entries:
'   { name, url (still image), w, h (source size, used for the aspect ratio),
'     anim? (animated WebP), check? (animated WebP to use once its size is checked),
'     zw? (zero-width overlay), unsized? (size unknown until loaded) }

' Roku's AnimatedImage plays lossy animated WebP (what 7TV serves) but not GIF ("Unable to
' detect decoder type") or BTTV's lossless WebP, so those are re-encoded by wsrv.nl, a free
' image proxy: same frames and timing, lossy WebP out.
function lossyWebpUrl(url as string) as string
    return "https://wsrv.nl/?url=" + url.EncodeUriComponent() + "&n=-1&output=webp"
end function

function isLossyWebpUrl(url as string) as boolean
    return url.Left(16) = "https://wsrv.nl/"
end function

' Emote lists to load for a channel. Later sources override earlier ones with the same
' name, matching Chatterino: channel emotes beat global ones, then FFZ > BTTV > 7TV.
function chatEmoteSources(channelId as string, providers as object) as object
    sources = []
    if providers.seventv = true
        sources.Push({ key: "7tv-global", url: "https://7tv.io/v3/emote-sets/global" })
    end if
    if providers.bttv = true
        sources.Push({ key: "bttv-global", url: "https://api.betterttv.net/3/cached/emotes/global" })
    end if
    if providers.ffz = true
        sources.Push({ key: "ffz-global", url: "https://api.frankerfacez.com/v1/set/global" })
    end if
    if channelId <> ""
        if providers.seventv = true
            sources.Push({ key: "7tv-channel", url: "https://7tv.io/v3/users/twitch/" + channelId })
        end if
        if providers.bttv = true
            sources.Push({ key: "bttv-channel", url: "https://api.betterttv.net/3/cached/users/twitch/" + channelId })
        end if
        if providers.ffz = true
            sources.Push({ key: "ffz-channel", url: "https://api.frankerfacez.com/v1/room/id/" + channelId })
        end if
    end if
    return sources
end function

function parseChatEmotes(key as string, json as dynamic) as object
    if json = invalid then return []
    if key.Left(4) = "7tv-" then return parseSevenTvEmotes(json)
    if key.Left(5) = "bttv-" then return parseBttvEmotes(json)
    if key.Left(4) = "ffz-" then return parseFfzEmotes(json)
    return []
end function

' 7TV v3: the global set has "emotes" at the top level, a user has them under "emote_set".
function parseSevenTvEmotes(json as object) as object
    entries = []
    list = json.emotes
    if list = invalid and json.emote_set <> invalid
        list = json.emote_set.emotes
    end if
    if list = invalid then return entries
    for each emote in list
        data = emote.data
        if emote.name <> invalid and data <> invalid and data.host <> invalid and data.host.url <> invalid
            base = data.host.url
            if base.Left(2) = "//" then base = "https:" + base
            entry = { name: emote.name, w: 32, h: 32 }
            animatedBytes = 0
            if data.host.files <> invalid
                for each file in data.host.files
                    if file.name = "1x.webp"
                        if file.width <> invalid and file.height <> invalid
                            entry.w = file.width
                            entry.h = file.height
                        end if
                        if file.size <> invalid then animatedBytes = file.size
                    end if
                end for
            end if
            if data.animated = true
                entry.url = base + "/2x_static.png"
                ' Very long animations stay still: AnimatedImage decodes the whole file in memory.
                if animatedBytes > 0 and animatedBytes <= 524288
                    entry.anim = base + "/1x.webp"
                end if
            else
                entry.url = base + "/2x.png"
            end if
            if emote.flags <> invalid and (Int(emote.flags) and 1) = 1
                entry.zw = true
            end if
            entries.Push(entry)
        end if
    end for
    return entries
end function

' BTTV: the global endpoint is an array; a channel has channelEmotes and sharedEmotes.
' BTTV doesn't report image sizes, so the overlay learns them once an image loads, and
' animated emotes (re-encoded, see lossyWebpUrl) keep animating only if a HEAD request
' shows the file is small enough (most are ~15 KB). Their still frame can be blank, so
' animating matters.
function parseBttvEmotes(json as object) as object
    entries = []
    lists = []
    if type(json) = "roArray"
        lists.Push(json)
    else
        if json.channelEmotes <> invalid then lists.Push(json.channelEmotes)
        if json.sharedEmotes <> invalid then lists.Push(json.sharedEmotes)
    end if
    ' BTTV's overlay emotes, the same list Chatterino treats as zero-width.
    zeroWidth = {}
    zeroWidth.SetModeCaseSensitive()
    for each code in ["SoSnowy", "IceCold", "SantaHat", "TopHat", "ReinDeer", "CandyCane", "cvMask", "cvHazmat"]
        zeroWidth[code] = true
    end for
    for each list in lists
        for each emote in list
            if emote.id <> invalid and emote.code <> invalid
                entry = { name: emote.code, url: "https://cdn.betterttv.net/emote/" + emote.id + "/2x.png", w: 28, h: 28, unsized: true }
                if emote.animated = true then entry.check = lossyWebpUrl("https://cdn.betterttv.net/emote/" + emote.id + "/1x.webp")
                if zeroWidth[emote.code] = true then entry.zw = true
                entries.Push(entry)
            end if
        end for
    end for
    return entries
end function

' FFZ v1: global sets are listed in default_sets; a room returns only its own sets.
function parseFfzEmotes(json as object) as object
    entries = []
    if json.sets = invalid then return entries
    setIds = []
    if json.default_sets <> invalid
        for each id in json.default_sets
            setIds.Push(id.ToStr())
        end for
    else
        for each id in json.sets
            setIds.Push(id)
        end for
    end if
    for each id in setIds
        emoteSet = json.sets[id]
        if emoteSet <> invalid and emoteSet.emoticons <> invalid
            for each emote in emoteSet.emoticons
                url = invalid
                if emote.urls <> invalid
                    url = emote.urls["2"]
                    if url = invalid then url = emote.urls["1"]
                end if
                if url <> invalid and emote.name <> invalid
                    if url.Left(2) = "//" then url = "https:" + url
                    entry = { name: emote.name, url: url, w: 28, h: 28 }
                    if emote.width <> invalid and emote.height <> invalid
                        entry.w = emote.width
                        entry.h = emote.height
                    end if
                    entries.Push(entry)
                end if
            end for
        end if
    end for
    return entries
end function

' Result of the HEAD request for an entry's animated file: animate it only when the file
' is small enough to download and decode comfortably (same 512 KB limit as 7TV).
sub applyEmoteSizeCheck(entry as object, responseCode as integer, headers as dynamic)
    size = 0
    if headers <> invalid and headers["content-length"] <> invalid then size = headers["content-length"].ToInt()
    if responseCode = 200 and size > 0 and size <= 524288 then entry.anim = entry.check
    entry.Delete("check")
end sub

' Merges the loaded lists into one case-sensitive name -> entry map (later sources win).
function buildChatEmoteMap(sources as object, lists as object) as object
    emotes = {}
    emotes.SetModeCaseSensitive()
    for each source in sources
        entries = lists[source.key]
        if entries <> invalid
            for each entry in entries
                emotes[entry.name] = entry
            end for
        end if
    end for
    return emotes
end function

' Twitch GQL request for global + channel chat badges.
function chatBadgeRequest(channel as string, deviceId as string) as object
    body = {
        "operationName": "ChatList_Badges",
        "variables": { "channelLogin": channel },
        "extensions": {
            "persistedQuery": {
                "version": 1,
                "sha256Hash": "86f43113c04606e6476e39dcd432dee47c994d77a83e54b732e11d4935f0cd08"
            }
        }
    }
    return {
        key: "badges",
        url: "https://gql.twitch.tv/gql",
        body: FormatJson(body),
        headers: {
            "Accept": "*/*",
            "Client-Id": "ue6666qo983tsx6so1t0vnawi233wa",
            "Device-ID": deviceId,
            "Origin": "https://android.tv.twitch.tv",
            "Referer": "https://android.tv.twitch.tv/"
        }
    }
end function

' Twitch GQL request for the channel's user id and its subscriber emotes (and whether each
' is animated).
function chatTwitchEmotesRequest(channel as string, deviceId as string) as object
    body = {
        "query": "query($login: String!) { user(login: $login) { id subscriptionProducts { emotes { id assetType } } } }",
        "variables": { "login": channel }
    }
    return {
        key: "twitch-emotes",
        url: "https://gql.twitch.tv/gql",
        body: FormatJson(body),
        headers: {
            "Accept": "*/*",
            "Client-Id": "ue6666qo983tsx6so1t0vnawi233wa",
            "Content-Type": "application/json",
            "Device-ID": deviceId
        }
    }
end function

' Returns Twitch emote id -> true for the channel's animated subscriber emotes.
function parseTwitchAnimatedEmotes(json as dynamic) as object
    animated = {}
    if json = invalid or json.data = invalid or json.data.user = invalid then return animated
    products = json.data.user.subscriptionProducts
    if products = invalid then return animated
    for each product in products
        if product <> invalid and product.emotes <> invalid
            for each emote in product.emotes
                if emote <> invalid and emote.id <> invalid and emote.assetType = "ANIMATED" then animated[emote.id] = true
            end for
        end if
    end for
    return animated
end function

' The channel's Twitch user id from that same response, or "".
function parseTwitchUserId(json as dynamic) as string
    if json = invalid or json.data = invalid or json.data.user = invalid then return ""
    id = json.data.user.id
    if id = invalid then return ""
    return id.ToStr()
end function

' Returns "setID/version" -> image URL for global and channel badges.
function parseTwitchBadges(json as dynamic) as object
    badges = {}
    if json = invalid or json.data = invalid then return badges
    addTwitchBadges(badges, json.data.badges)
    if json.data.user <> invalid
        addTwitchBadges(badges, json.data.user.broadcastBadges)
    end if
    return badges
end function

sub addTwitchBadges(badges as object, list as dynamic)
    if list = invalid then return
    for each badge in list
        if badge <> invalid and badge.setID <> invalid and badge.version <> invalid and badge.image2x <> invalid
            badges[badge.setID + "/" + badge.version] = badge.image2x
        end if
    end for
end sub
