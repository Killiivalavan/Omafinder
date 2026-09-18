import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Fuzzy.js" as Fuzzy

Item {
    id: root

    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null
    property string home: Quickshell.env("HOME")

    property bool opened: false
    property string currentDir: home
    property string filterText: ""
    property int selectedIndex: 0
    property bool cursorActive: false
    property bool showHidden: false
    property var dirEntries: [] // {name, path, isDir, hidden}
    property string pendingSearchQuery: ""
    property bool isSearching: false
    property var frecency: ({})
    property string statePath: home + "/.local/state/omarchy/omafinder/state.json"
    property string stateDir: home + "/.local/state/omarchy/omafinder"
    property int animationDurationIn: 130
    property int animationDurationOut: 80
    property bool isAnimatingOut: false
    // Clipboard for file copy/cut/paste
    property string clipboardPath: ""
    property string clipboardOp: "" // "copy" or "cut"
    // Open With mode
    property bool openWithMode: false
    property string openWithFile: ""
    readonly property var appLibrary: shell && shell.appLibrary ? shell.appLibrary : null
    // Trash confirm
    property bool trashConfirmOpen: false
    property var trashTarget: null
    // Help
    property bool helpOpen: false
    // Rename
    property bool renameOpen: false
    property var renameTarget: null // {path, name, isDir}
    property string renameText: ""
    property string renameError: ""
    property int renameSelected: 1
    // For Open With mime filtering
    property string openWithMime: ""
    property var openWithRecommendedIds: []
    property var openWithAllIds: []

    // Colors / style — mirror menu tokens
    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property color border: Color.menu.border
    property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
    property color scrim: Color.menu.scrim
    property color selectedBackground: Color.menu.selectedBackground
    property color selectedText: Color.menu.selectedText
    property color selectedBorder: Color.menu.selectedBorder
    property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
    readonly property int cornerRadius: Style.cornerRadius
    property string fontFamily: Style.font.menuFamily
    property int contentMargin: Style.spacing.panelPadding
    property int headerHeight: Math.max(Style.space(42), Style.font.title + Style.spacing.controlPaddingY * 2 + 6)
    property int contentSpacing: Style.spacing.md
    property int cardWidth: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
    property int rowHeight: Math.max(Style.space(46), Style.font.body + Style.font.caption + 10)
    property int rowSpacing: Style.spacing.xs
    property int visibleRows: 9
    property int cardHeight: {
        var rows = Math.min(displayModel.count, visibleRows)
        if (rows === 0) rows = 1
        var listH = rows * rowHeight + Math.max(0, rows - 1) * rowSpacing
        var total = contentMargin*2 + headerHeight + contentSpacing + listH
        // Single persistent footer — 28 + spacing for breathing room so footer not clipped
        total += Style.space(28) + Style.spacing.md
        return Math.min(total, panel.height - Style.gapsOut*2)
    }

    // ---- Lifecycle ----
    function open(payloadJson) {
        var payload = {}
        try { payload = JSON.parse(payloadJson || "{}") } catch(e) { payload = {} }
        if (stateFile.text() && !stateLoaded) loadState(stateFile.text())
        if (!currentDir || currentDir === "") currentDir = home
        root.opened = true
        root.isAnimatingOut = false
        root.filterText = ""
        root.selectedIndex = 0
        root.cursorActive = true
        pendingSearchQuery = ""
        isSearching = false
        openWithMode = false
        openWithFile = ""
        if (searchProc.running) searchProc.running = false
        searchDebounce.stop()
        root.rebuildDisplay()
        refreshDir()
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
    }

    function close() {
        root.opened = false
        root.isAnimatingOut = false
        openWithMode = false
        openWithFile = ""
        trashConfirmOpen = false
        trashTarget = null
        helpOpen = false
        renameOpen = false
        renameTarget = null
        renameError = ""
        if (searchProc.running) searchProc.running = false
        searchDebounce.stop()
        isSearching = false
    }

    function dismiss() {
        if (renameOpen) {
            cancelRename()
            return
        }
        if (helpOpen) {
            closeHelp()
            return
        }
        if (trashConfirmOpen) {
            cancelTrashConfirm()
            return
        }
        if (root.isAnimatingOut) return
        // If in Open With, just exit that mode instead of dismissing overlay
        if (openWithMode) {
            exitOpenWithMode()
            return
        }
        root.isAnimatingOut = true
        if (searchProc.running) searchProc.running = false
        searchDebounce.stop()
        dismissTimer.restart()
    }

    Timer {
        id: dismissTimer
        interval: root.animationDurationOut
        repeat: false
        onTriggered: {
            root.opened = false
            root.isAnimatingOut = false
            if (root.shell && typeof root.shell.hide === "function")
                root.shell.hide(root.manifest ? root.manifest.id : "killie.omafinder")
        }
    }

    function toggle() {
        if (root.opened) root.dismiss()
        else root.open("{}")
    }

    // ---- State persistence ----
    property bool stateLoaded: false
    function loadState(raw) {
        try {
            var data = JSON.parse(String(raw||"").trim() || "{}")
            if (data.currentDir && typeof data.currentDir === "string") {
                // validate it's a string path, keep home fallback if empty
                var cd = String(data.currentDir)
                if (cd) currentDir = cd
            }
            if (data.frecency && typeof data.frecency === "object") frecency = data.frecency
            if (typeof data.showHidden === "boolean") {
                showHidden = data.showHidden
            }
            stateLoaded = true
        } catch(e) { stateLoaded = true }
    }
    function saveState() {
        var payload = {
            currentDir: currentDir,
            frecency: frecency,
            showHidden: showHidden
        }
        // Atomic write via FileView (temp file + rename) — a crash mid-write
        // can no longer leave a truncated state.json behind.
        stateFile.setText(JSON.stringify(payload, null, 2) + "\n")
    }

    // FileView does not create parent dirs — ensure the state dir exists once.
    Process {
        id: stateDirProc
        command: ["bash","-lc", "mkdir -p " + Util.shellQuote(stateDir)]
    }

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.loadState(text())
        onLoadFailed: root.stateLoaded = true
    }
    Component.onCompleted: stateDirProc.running = true

    // ---- Path helpers ----
    function tildeCollapse(path) {
        if (!path) return ""
        if (path === home) return "~"
        if (path.indexOf(home + "/") === 0) return "~" + path.slice(home.length)
        return path
    }

    function expandPath(input) {
        return Fuzzy.expandPath(input, home)
    }

    function normalizeDir(dir) {
        var d = String(dir||"").trim()
        if (!d) return home
        d = expandPath(d)
        // remove trailing slash except root
        if (d.length > 1 && d.charAt(d.length-1) === "/") d = d.slice(0,-1)
        return d
    }

    function parentDir(dir) {
        var d = normalizeDir(dir)
        if (d === "/") return "/"
        var idx = d.lastIndexOf("/")
        if (idx === -1) return home
        if (idx === 0) return "/"
        return d.slice(0, idx)
    }

    function joinPath(base, name) {
        var b = normalizeDir(base)
        if (b === "/") return "/" + name
        return b + "/" + name
    }

    function isHiddenName(name) {
        return String(name||"").charAt(0) === "."
    }
    function mimeForPath(path, isDir) {
        if (isDir) return "inode/directory"
        var n = String(path||"")
        var dot = n.lastIndexOf(".")
        if (dot === -1) return "application/octet-stream"
        var ext = n.slice(dot+1).toLowerCase()
        var map = {
            "py": "text/x-python", "js": "application/javascript", "ts": "application/x-typescript",
            "tsx": "application/x-typescript", "jsx": "application/javascript", "json": "application/json",
            "html": "text/html", "css": "text/css", "md": "text/markdown", "txt": "text/plain",
            "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "gif": "image/gif", "svg": "image/svg+xml", "mp4": "video/mp4", "mp3": "audio/mpeg",
            "zip": "application/zip", "tar": "application/x-tar", "gz": "application/gzip",
            "rs": "text/x-rust", "go": "text/x-go", "c": "text/x-csrc", "cpp": "text/x-c++src",
            "h": "text/x-chdr", "java": "text/x-java", "rb": "text/x-ruby", "sh": "application/x-shellscript",
            "toml": "text/plain", "yaml": "text/x-yaml", "yml": "text/x-yaml", "xml": "application/xml",
            "csv": "text/csv", "log": "text/plain", "conf": "text/plain", "cfg": "text/plain"
        }
        return map[ext] || "application/octet-stream"
    }
    function iconForPath(path, isDir) {
        if (isDir) return "folder"
        var n = String(path||"")
        var dot = n.lastIndexOf(".")
        if (dot === -1) return "text-x-generic"
        var ext = n.slice(dot+1).toLowerCase()
        var map = {
            "py": "text-x-python", "js": "text-x-javascript", "ts": "text-x-javascript",
            "json": "application-json", "html": "text-html", "css": "text-css",
            "md": "text-x-generic", "txt": "text-x-generic", "pdf": "application-pdf",
            "png": "image-x-generic", "jpg": "image-x-generic", "jpeg": "image-x-generic",
            "gif": "image-x-generic", "svg": "image-x-generic", "mp4": "video-x-generic",
            "mp3": "audio-x-generic", "zip": "application-x-zip", "tar": "application-x-archive",
            "gz": "application-x-archive", "rs": "text-x-rust", "go": "text-x-go",
            "c": "text-x-c", "cpp": "text-x-c++", "h": "text-x-chdr", "sh": "application-x-shellscript",
            "toml": "text-x-generic", "yaml": "text-x-generic", "yml": "text-x-generic"
        }
        return map[ext] || "text-x-generic"
    }

    // ---- Frecency ----
    function bumpFrecency(path) {
        var p = String(path||"")
        if (!p) return
        var next = {}
        for (var k in frecency) next[k] = frecency[k]
        var rec = next[p] || {count:0, last:0}
        rec.count = (rec.count||0) + 1
        rec.last = Date.now()
        next[p] = rec
        // also bump parent dir
        var dir = p
        // if file, use its dir
        if (!isDirPath(p)) dir = Fuzzy.dirname(p)
        else dir = normalizeDir(p)
        if (dir && dir !== p) {
            var drec = next[dir] || {count:0,last:0}
            drec.count = (drec.count||0) + 0.5
            drec.last = Date.now()
            next[dir] = drec
        }
        frecency = next
        saveState()
    }

    function isDirPath(path) {
        // heuristic: we track isDir in dirEntries but for arbitrary path, check trailing slash? we will stat async for accurate.
        return String(path||"").charAt(String(path).length-1) === "/"
    }

    function frecencyScore(path) {
        var rec = frecency[String(path||"")]
        if (!rec) return 0
        var ageHours = (Date.now() - (rec.last||0)) / 3600000
        var decay = Math.exp(-ageHours/72) // 3 days half-life-ish
        return (rec.count||0) * 10 * decay
    }

    // ---- Directory listing ----
    function refreshDir() {
        var dir = normalizeDir(currentDir)
        currentDir = dir
        var lsFlag = showHidden ? "-A" : ""
        // Use ls -1 -p --group-directories-first ; fallback if not supported
        var cmd = "ls -1 -p --group-directories-first " + lsFlag + " -- " + Util.shellQuote(dir) + " 2>/dev/null || ls -1 -p " + lsFlag + " -- " + Util.shellQuote(dir) + " 2>/dev/null"
        listProc.command = ["bash","-lc", cmd]
        listProc.running = true
    }

    Process {
        id: listProc
        stdout: StdioCollector { id: listOutput; waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code){
            var raw = String(listOutput.text||"")
            var lines = raw.split("\n")
            var entries = []
            for (var i=0;i<lines.length;i++){
                var line = lines[i]
                if (!line) continue
                var isDir = line.charAt(line.length-1) === "/"
                var name = isDir ? line.slice(0,-1) : line
                if (!name) continue
                if (!showHidden && isHiddenName(name)) continue
                var full = joinPath(currentDir, name)
                if (isDir) full += "/"
                entries.push({name:name, path:full, isDir:isDir, hidden:isHiddenName(name)})
            }
            dirEntries = entries
            if (pendingRenameSelect) {
                var want = pendingRenameSelect
                pendingRenameSelect = ""
                for (var rs=0; rs<entries.length; rs++) {
                    if (entries[rs].path === want || normalizeDir(entries[rs].path) === normalizeDir(want)) {
                        rebuildDisplay()
                        selectedIndex = rs
                        cursorActive = true
                        layoutSerial++
                        Qt.callLater(function(){ resultList.positionViewAtIndex(selectedIndex, ListView.Contain) })
                        return
                    }
                }
            }
            if (root.opened && !openWithMode) {
                // Only rebuild if not in search mode and not in Open With
                var q = String(filterText||"").trim()
                if (!q || (Fuzzy.isPathLike(q) && q.indexOf('/')!==-1)) root.rebuildDisplay()
                // If in search mode or Open With, keep current display
            }
        }
    }

    // ---- Search (on-demand, debounced) ----
    Timer {
        id: searchDebounce
        interval: 150
        repeat: false
        onTriggered: root.performSearch(pendingSearchQuery)
    }

    function performSearch(query) {
        var q = String(query||"").trim()
        if (!q) { isSearching = false; rebuildDisplay(); return }
        // If query is path-like, don't do global search - handle via rebuildDisplay
        if (Fuzzy.isPathLike(q) && q.indexOf('/') !== -1) { isSearching = false; rebuildDisplay(); return }
        // Don't search for very short queries (1 char) - just filter current dir
        if (q.length < 2) { isSearching = false; rebuildDisplay(); return }
        isSearching = true
        // Show transient searching state
        displayModel.clear()
        displayModel.append({name:"Searching…", path:"", isDir:false, detail:"", hidden:false, iconName: "system-search"})
        cursorActive = false
        var quotedHome = Util.shellQuote(home)
        var quotedPattern = Util.shellQuote(q)
        // Use fd with full-path, fixed strings, case-insensitive, hidden, no-ignore, absolute
        var cmd = "if command -v fd >/dev/null 2>&1; then fd -u -a -p --max-results 120 -i -F -- " + quotedPattern + " " + quotedHome + " 2>/dev/null | head -n 120; else find " + quotedHome + " -mindepth 1 -iname " + Util.shellQuote("*"+q+"*") + " -print 2>/dev/null | head -n 120; fi"
        searchProc.command = ["bash","-lc", cmd]
        searchProc.running = true
    }

    Process {
        id: searchProc
        stdout: StdioCollector { id: searchOutput; waitForEnd: true }
        onExited: function(code){
            isSearching = false
            if (!root.opened) return
            // If filter has changed since we started, ignore stale result
            var currentQ = String(filterText||"").trim()
            if (currentQ !== pendingSearchQuery) return
            var raw = String(searchOutput.text||"").trim()
            if (!raw) {
                // No results - show empty with hint, keep browsing entries as fallback
                displayModel.clear()
                // Also include current dir fuzzy matches as fallback
                var fallback = []
                for (var fi=0; fi<dirEntries.length; fi++){
                    var e = dirEntries[fi]
                    if (!showHidden && e.hidden) continue
                    if (Fuzzy.fuzzyScore(currentQ, e.path) >=0) fallback.push(e)
                }
                fallback.sort(function(a,b){
                    var sa = Fuzzy.fuzzyScore(currentQ, a.path) + frecencyScore(a.path)
                    var sb = Fuzzy.fuzzyScore(currentQ, b.path) + frecencyScore(b.path)
                    return sb - sa
                })
                for (var fbi=0; fbi<fallback.length && fbi<30; fbi++){
                    var fe = fallback[fbi]
                    displayModel.append({name: fe.name + (fe.isDir?"/":""), path: fe.path, isDir: fe.isDir, detail: tildeCollapse(fe.path), hidden: fe.hidden, iconName: iconForPath(fe.path, fe.isDir), appIcon: "", appId: ""})
                }
                if (displayModel.count===0) {
                    // keep empty, rebuildDisplay will show "No results"
                } else {
                    selectedIndex = 0; cursorActive = true
                }
                layoutSerial++
                if (displayModel.count>0) Qt.callLater(function(){ resultList.positionViewAtIndex(selectedIndex, ListView.Contain) })
                return
            }
            var lines = raw.split("\n")
            var candidates = []
            for (var i=0;i<lines.length;i++){
                var p = String(lines[i]||"").trim()
                if (!p) continue
                // Ensure absolute
                if (p.charAt(0) !== "/") {
                    if (p.indexOf("./")===0) p = p.slice(2)
                    p = home + "/" + p
                }
                if (!showHidden && isHiddenName(Fuzzy.basename(p))) continue
                candidates.push(p)
            }
            // Also add current dir entries that match fuzzily but weren't in fd results (fd is substring, fuzzy may find more)
            for (var ci=0; ci<dirEntries.length; ci++){
                var de = dirEntries[ci]
                if (!showHidden && de.hidden) continue
                if (candidates.indexOf(de.path) !== -1) continue
                if (Fuzzy.fuzzyScore(currentQ, de.path) >=0) candidates.push(de.path)
            }
            // Score with fuzzy + frecency
            var scored = []
            for (var si=0; si<candidates.length; si++){
                var cp = candidates[si]
                var s = Fuzzy.fuzzyScore(currentQ, cp)
                if (s < 0) continue
                s += frecencyScore(cp)
                scored.push({path: cp, score: s})
            }
            scored.sort(function(a,b){
                if (b.score !== a.score) return b.score - a.score
                if (a.path.length !== b.path.length) return a.path.length - b.path.length
                return a.path.localeCompare(b.path)
            })
            displayModel.clear()
            var limit = Math.min(scored.length, 100)
            for (var si2=0; si2<limit; si2++){
                var spath = scored[si2].path
                var isDirFlag = spath.charAt(spath.length-1) === "/"
                if (!isDirFlag) {
                    for (var dk=0; dk<dirEntries.length; dk++) if (dirEntries[dk].path === spath) { isDirFlag = dirEntries[dk].isDir; break }
                    // heuristic: if many candidates start with spath + "/", it's a dir
                    if (!isDirFlag) {
                        for (var gk=0; gk<candidates.length; gk++) if (candidates[gk].indexOf(spath + "/") === 0) { isDirFlag = true; break }
                    }
                }
                var dname = Fuzzy.basename(spath)
                if (isDirFlag) {
                    if (dname === "") dname = spath
                    dname += "/"
                    if (spath.charAt(spath.length-1) !== "/") spath += "/"
                }
                displayModel.append({name: dname, path: spath, isDir: isDirFlag, detail: tildeCollapse(spath), hidden: isHiddenName(Fuzzy.basename(spath)), iconName: iconForPath(spath, isDirFlag), appIcon: "", appId: ""})
            }
            layoutSerial++
            if (displayModel.count===0) { selectedIndex=0; cursorActive=false }
            else { selectedIndex=0; cursorActive=true }
            Qt.callLater(function(){ if (displayModel.count>0) resultList.positionViewAtIndex(selectedIndex, ListView.Contain) })
        }
    }

    // ---- Search / browse decision ----
    function rebuildDisplay() {
        // If we're in debounced search mode, let performSearch handle display
        var q = String(filterText||"").trim()
        if (isSearching) return
        if (openWithMode) {
            return
        }
        // If query is non-empty, non-path, >=2 chars and not yet searched, we should be in search - but if we are here via direct call (e.g., initial), handle via performSearch
        if (q && !Fuzzy.isPathLike(q) || (Fuzzy.isPathLike(q) && q.indexOf('/')===-1)) {
            if (q.length >= 2 && !isPathLikeForSearch(q)) {
                // This branch is for search - but setFilter already handles debounce; if we reach here directly (e.g., refreshDir), we still want to trigger search
                // Only trigger if pendingSearchQuery doesn't match
                if (pendingSearchQuery !== q) {
                    pendingSearchQuery = q
                    searchDebounce.restart()
                    return
                }
            }
        }
        // Fall through to browse/path handling below (for empty or path-like)
        displayModel.clear()
        var qLower = q.toLowerCase()

        var isPathInput = Fuzzy.isPathLike(q) && q.length > 1

        if (isPathInput && q.indexOf('/') !== -1) {
            var expanded = expandPath(q)
            var base = expanded
            var prefix = ""
            if (expanded.charAt(expanded.length-1) === "/") {
                base = expanded.slice(0,-1) || "/"
                prefix = ""
            } else {
                base = Fuzzy.dirname(expanded)
                prefix = Fuzzy.basename(expanded)
            }
            if (!base) base = "."
            base = normalizeDir(base)
            if (base === currentDir) {
                var filtered = []
                for (var di=0; di<dirEntries.length; di++) {
                    var e = dirEntries[di]
                    if (prefix && e.name.toLowerCase().indexOf(prefix.toLowerCase()) !== 0) {
                        if (Fuzzy.fuzzyScore(prefix, e.name) < 0) continue
                    }
                    filtered.push(e)
                }
                filtered.sort(function(a,b){
                    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
                    var sa = frecencyScore(a.path), sb = frecencyScore(b.path)
                    if (sb !== sa) return sb - sa
                    return a.name.localeCompare(b.name)
                })
                for (var fi=0; fi<filtered.length && fi<100; fi++) {
                    var fe = filtered[fi]
                    displayModel.append({
                        name: fe.name + (fe.isDir?"/":""),
                        path: fe.path,
                        isDir: fe.isDir,
                        detail: tildeCollapse(fe.path),
                        hidden: fe.hidden, iconName: iconForPath(fe.path, fe.isDir), appIcon: "", appId: ""})
                }
                if (displayModel.count===0 && !isSearching) {
                    displayModel.append({name:"No match", path:"", isDir:false, detail:"Try a different prefix or check hidden (Ctrl+H)", hidden:false, iconName: "dialog-information"})
                }
            } else {
                displayModel.append({name: Fuzzy.basename(base) + "/", path: normalizeDir(base) + "/", isDir:true, detail: tildeCollapse(normalizeDir(base)), hidden:false, iconName: "folder"})
            }
            layoutSerial += 1
            if (displayModel.count>0) { selectedIndex = Math.min(selectedIndex, displayModel.count-1); cursorActive=true } else { selectedIndex=0; cursorActive=false }
            Qt.callLater(function(){ if (displayModel.count>0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
            return
        }

        if (!q) {
            var sorted = dirEntries.slice(0)
            sorted.sort(function(a,b){
                if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
                var sa = frecencyScore(a.path), sb = frecencyScore(b.path)
                if (Math.abs(sb-sa) > 0.1) return sb - sa
                return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
            })
            for (var bi=0; bi<sorted.length; bi++) {
                var be = sorted[bi]
                displayModel.append({
                    name: be.name + (be.isDir?"/":""),
                    path: be.path,
                    isDir: be.isDir,
                    detail: be.isDir ? "" : tildeCollapse(be.path),
                    hidden: be.hidden, iconName: iconForPath(be.path, be.isDir), appIcon: "", appId: ""})
            }
        } else {
            // Small query (<2 chars) or non-path fuzzy on current dir only (no global)
            if (q.length < 2) {
                var smallFiltered = []
                for (var si=0; si<dirEntries.length; si++){
                    var se = dirEntries[si]
                    if (!showHidden && se.hidden) continue
                    if (Fuzzy.fuzzyScore(q, se.name) >=0 || se.name.toLowerCase().indexOf(qLower) !== -1) smallFiltered.push(se)
                }
                smallFiltered.sort(function(a,b){
                    var sA = Fuzzy.fuzzyScore(q, a.name) + frecencyScore(a.path)
                    var sB = Fuzzy.fuzzyScore(q, b.name) + frecencyScore(b.path)
                    return sB - sA
                })
                for (var sfi=0; sfi<smallFiltered.length && sfi<50; sfi++){
                    var sfe = smallFiltered[sfi]
                    displayModel.append({name: sfe.name + (sfe.isDir?"/":""), path: sfe.path, isDir: sfe.isDir, detail: tildeCollapse(sfe.path), hidden: sfe.hidden, iconName: iconForPath(sfe.path, sfe.isDir), appIcon: "", appId: ""})
                }
                if (displayModel.count===0) displayModel.append({name:"No results", path:"", isDir:false, detail:'Type more characters for global search', hidden:false, iconName: "dialog-information"})
            } else {
                // For longer queries, we should have triggered search via debounce - but if we are here without search, fallback to local fuzzy
                var localFiltered = []
                for (var li=0; li<dirEntries.length; li++){
                    var le = dirEntries[li]
                    if (!showHidden && le.hidden) continue
                    if (Fuzzy.fuzzyScore(q, le.path) >=0) localFiltered.push(le)
                }
                localFiltered.sort(function(a,b){
                    var sA2 = Fuzzy.fuzzyScore(q, a.path) + frecencyScore(a.path)
                    var sB2 = Fuzzy.fuzzyScore(q, b.path) + frecencyScore(b.path)
                    return sB2 - sA2
                })
                for (var lfi=0; lfi<localFiltered.length && lfi<50; lfi++){
                    var lfe = localFiltered[lfi]
                    displayModel.append({name: lfe.name + (lfe.isDir?"/":""), path: lfe.path, isDir: lfe.isDir, detail: tildeCollapse(lfe.path), hidden: lfe.hidden, iconName: iconForPath(lfe.path, lfe.isDir), appIcon: "", appId: ""})
                }
                // If no local results, trigger global search now (if not already)
                if (displayModel.count===0) {
                    pendingSearchQuery = q
                    searchDebounce.restart()
                    displayModel.clear()
                    displayModel.append({name:"Searching…", path:"", isDir:false, detail:"", hidden:false, iconName: "system-search"})
                    cursorActive=false
                }
            }
        }

        layoutSerial += 1
        if (displayModel.count===0) { selectedIndex=0; cursorActive=false }
        else if (selectedIndex>=displayModel.count) { selectedIndex=displayModel.count-1; cursorActive=true }
        else if (selectedIndex<0) { selectedIndex=0; cursorActive=true }
        else if (!cursorActive && displayModel.count>0) { cursorActive=true }

        Qt.callLater(function(){ if (displayModel.count>0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
    }

    function isPathLikeForSearch(q) {
        return Fuzzy.isPathLike(q) && q.indexOf('/') !== -1
    }

    property int layoutSerial: 0

    // ---- Selection / activation ----
    function select(delta) {
        if (displayModel.count===0) return
        root.disarmPointer()
        if (!cursorActive) { cursorActive=true; selectedIndex = delta<0 ? displayModel.count-1 : 0 }
        else selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
        resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
    }

    function selectAbsolute(idx) {
        if (displayModel.count===0) return
        root.disarmPointer()
        cursorActive=true
        selectedIndex = Math.max(0, Math.min(idx, displayModel.count-1))
        resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
    }

    function setFilter(next) {
        root.filterText = next
        root.selectedIndex = 0
        root.cursorActive = true
        root.disarmPointer()
        if (openWithMode) {
            rebuildAppDisplay()
            return
        }
        var q = String(next||"").trim()
        // Path-like or empty: immediate rebuild (browse)
        if (!q || (Fuzzy.isPathLike(q) && q.indexOf('/') !== -1)) {
            if (searchProc.running) searchProc.running = false
            searchDebounce.stop()
            isSearching = false
            root.rebuildDisplay()
        } else if (q.length < 2) {
            // Short query: local only, immediate
            if (searchProc.running) searchProc.running = false
            searchDebounce.stop()
            isSearching = false
            root.rebuildDisplay()
        } else {
            // Longer query: debounced global search
            pendingSearchQuery = q
            searchDebounce.restart()
            // Optimistically show local matches immediately, then global will replace
            root.rebuildDisplay()
        }
    }

    function disarmPointer(){ pointerGate.reset() }
    function selectFromPointer(index, item, mouse){
        if (!pointerGate.moved(item, mouse)) return
        cursorActive=true
        selectedIndex=index
    }

    function goBack() {
        var parent = parentDir(currentDir)
        if (parent === currentDir) return false
        currentDir = parent
        saveState()
        // bump parent frecency?
        refreshDir()
        // clear filter? Keep filter but rebuild
        rebuildDisplay()
        return true
    }

    function navigateToDir(dirPath) {
        var d = normalizeDir(dirPath)
        currentDir = d
        bumpFrecency(d + "/")
        saveState()
        filterText = ""
        selectedIndex = 0
        refreshDir()
        rebuildDisplay()
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
    }

    // Check if path is dir via stat (async) then act
    property string pendingActivatePath: ""

    function activateIndex(index) {
        if (index<0 || index>=displayModel.count) return
        var row = displayModel.get(index)
        var path = String(row.path||"")
        if (!path) return

        // If row isDir flag is true, we can navigate immediately without stat? But to be safe, stat to confirm.
        // For path-like input where user typed a direct path and pressed Enter without selecting, handle that separately.

        // Use stat to determine real type, because fuzzy globalPaths isDir heuristic may be stale.
        pendingActivatePath = path
        // Use test -d via bash
        var cmd = "if [ -d " + Util.shellQuote(path) + " ]; then echo DIR; elif [ -e " + Util.shellQuote(path) + " ]; then echo FILE; else echo MISSING; fi"
        statProc.command = ["bash","-lc", cmd]
        statProc.running = true
    }

    Process {
        id: statProc
        property string collected: ""
        stdout: SplitParser { onRead: function(l){ statProc.collected += l + "\n" } }
        onStarted: collected = ""
        onExited: function(code){
            var out = String(collected||"").trim()
            var path = root.pendingActivatePath
            root.pendingActivatePath = ""
            if (!path) return
            if (out === "DIR") {
                var dir = path
                if (dir.charAt(dir.length-1) !== "/") dir += "/"
                dir = normalizeDir(dir)
                root.navigateToDir(dir)
            } else if (out === "FILE") {
                root.openFile(path)
            } else {
                // Missing: maybe it's a dir we guessed? Try to treat as dir navigation if ends with /
                if (path.charAt(path.length-1)==="/") {
                    // Try to create? Or just inform
                    // For now, try to navigate anyway if plausible
                    var tryDir = normalizeDir(path)
                    // check if parent exists? just navigate
                    root.navigateToDir(tryDir)
                } else {
                    // Try to open as file anyway via xdg-open? It will error silently.
                    root.openFile(path)
                }
            }
        }
    }

    function openFile(path) {
        var p = String(path||"")
        if (!p) return
        // Normalize: if dir without slash, ensure no slash
        // Use xdg-open detached
        // Bump frecency before dismiss
        bumpFrecency(p)
        saveState()
        // Use execDetached with shellQuote
        Util.execDetached("xdg-open " + Util.shellQuote(p) + " >/dev/null 2>&1 &")
        // Also try gio open fallback
        root.dismiss()
    }

    function handleEnterOnFilter() {
        var q = String(filterText||"").trim()
        if (!q) {
            if (displayModel.count>0 && cursorActive) activateIndex(selectedIndex)
            return
        }
        // If filter is a direct path that exists, act on it directly (even if not in list)
        var expanded = expandPath(q)
        // If expanded looks like path and exists, use it
        // We can test synchronously via statProc but need async; for now check if filterText matches any display row exactly
        for (var i=0;i<displayModel.count;i++) {
            var r = displayModel.get(i)
            if (String(r.path).toLowerCase() === expanded.toLowerCase() || String(r.name).toLowerCase()===q.toLowerCase()) {
                activateIndex(i)
                return
            }
        }
        // Check if expanded path exists as file/dir via async stat
        // If q contains no slash and not path-like, but user pressed enter on empty-ish? Use selected row
        if (!Fuzzy.isPathLike(q)) {
            if (displayModel.count>0 && cursorActive) activateIndex(selectedIndex)
            else {
                // Try expanded as file in currentDir
                var tryFile = joinPath(currentDir, q)
                pendingActivatePath = tryFile
                statDirectProc.command = ["bash","-lc", "if [ -e " + Util.shellQuote(expanded) + " ] || [ -d " + Util.shellQuote(expanded) + " ]; then if [ -d " + Util.shellQuote(expanded) + " ]; then echo DIR; else echo FILE; fi; else echo MISSING; fi"]
                statDirectProc.running = true
                // store q for fallback
                pendingDirectFilter = q
            }
            return
        }
        // Path-like: test expanded
        pendingActivatePath = expanded
        // Reuse statProc for direct path
        var cmd = "if [ -d " + Util.shellQuote(expanded) + " ]; then echo DIR; elif [ -e " + Util.shellQuote(expanded) + " ]; then echo FILE; else echo MISSING; fi"
        statDirectProc.command = ["bash","-lc", cmd]
        statDirectProc.running = true
        pendingDirectFilter = q
    }

    property string pendingDirectFilter: ""

    Process {
        id: statDirectProc
        property string collected: ""
        stdout: SplitParser { onRead: function(l){ statDirectProc.collected += l + "\n" } }
        onStarted: collected = ""
        onExited: function(c){
            var out = String(collected||"").trim()
            var exp = root.pendingActivatePath
            var q = root.pendingDirectFilter
            root.pendingActivatePath=""
            root.pendingDirectFilter=""
            if (!exp) return
            if (out==="DIR") {
                var d = normalizeDir(exp)
                navigateToDir(d)
            } else if (out==="FILE") {
                openFile(exp)
            } else {
                // Not found — fallback to activating selected index if any
                if (displayModel.count>0 && cursorActive) activateIndex(selectedIndex)
                else {
                    // Try to treat q as search query and activate first match if exists
                    // Already handled — just do nothing or show feedback
                }
            }
        }
    }

    // ---- Secondary actions ----
    function copyPath(path) {
        var p = String(path||"")
        if (!p) return
        var cmd = "printf %s " + Util.shellQuote(p) + " | (command -v wl-copy >/dev/null 2>&1 && wl-copy || xclip -selection clipboard 2>/dev/null || true)"
        Util.execDetached(cmd)
        bumpFrecency(p)
        root.dismiss()
    }
    function copyFileToClipboard(path, op) {
        var p = String(path||"")
        if (!p) return
        clipboardPath = p
        clipboardOp = op || "copy"
        // Put file uri on system clipboard for interoperability (nautilus, etc.)
        var uri = "file://" + p
        // Ensure absolute and handle dir trailing slash for uri
        Util.execDetached("printf %s " + Util.shellQuote(uri) + " | wl-copy --type text/uri-list 2>/dev/null || printf %s " + Util.shellQuote(uri) + " | xclip -selection clipboard -t text/uri-list 2>/dev/null || true")
        // Also copy plain path as fallback
        bumpFrecency(p)
    }
    function copyFile(path) {
        copyFileToClipboard(path, "copy")
        // Stay open and jump home for a quick paste — no reopen needed
        navigateToDir(home)
    }
    function cutFile(path) {
        copyFileToClipboard(path, "cut")
        navigateToDir(home)
    }
    function pasteClipboard() {
        var src = String(clipboardPath||"")
        var op = String(clipboardOp||"copy")
        if (!src) {
            // Fallback: read uri-list from the system clipboard via wl-paste/xclip,
            // then copy into the current dir — src never enters the JS layer.
            pasteProc.command = ["bash","-lc", "src=$(wl-paste --type text/uri-list 2>/dev/null | tr -d '\\r' | head -n1 | sed 's/^file:\\/\\///;s/%20/ /g' | tr -d '\\n'); if [ -z \"$src\" ]; then src=$(xclip -selection clipboard -o -t text/uri-list 2>/dev/null | head -n1 | sed 's/^file:\\/\\///' | tr -d '\\n'); fi; if [ -z \"$src\" ]; then echo NOCLIP; exit 0; fi; src=$(printf %s \"$src\" | sed 's/%0D//g' | head -n1); if [ ! -e \"$src\" ]; then echo NOTFOUND:$src; exit 0; fi; dest=" + Util.shellQuote(currentDir) + "/$(basename -- \"$src\"); if [ -e \"$dest\" ]; then echo EXISTS:$dest; exit 0; fi; gio copy \"$src\" \"$dest\" 2>/dev/null || cp -a -- \"$src\" \"$dest\" 2>/dev/null; if [ $? -eq 0 ]; then echo COPIED:$dest; else echo FAIL; fi"]
            pasteProc.running = true
            return
        }
        if (!src) return
        var destBase = normalizeDir(currentDir)
        var baseName = Fuzzy.basename(src)
        if (!baseName) baseName = "pasted"
        var dest = joinPath(destBase, baseName)
        // Avoid overwriting — find unused name
        var cmd
        if (op === "cut") {
            cmd = "src=" + Util.shellQuote(src) + "; dest=" + Util.shellQuote(dest) + "; baseDest=\"$dest\"; i=1; while [ -e \"$dest\" ]; do dest=\"${baseDest%.*}_$i\"; case \"$baseDest\" in *.*) ext=\".${baseDest##*.}\"; base=\"${baseDest%.*}\"; dest=\"${base}_$i$ext\";; esac; i=$((i+1)); done; gio move -- \"$src\" \"$dest\" 2>/dev/null || mv -- \"$src\" \"$dest\" 2>/dev/null; ec=$?; if [ $ec -eq 0 ]; then echo MOVED:$dest; else echo FAIL; fi"
        } else {
            cmd = "src=" + Util.shellQuote(src) + "; dest=" + Util.shellQuote(dest) + "; baseDest=\"$dest\"; i=1; while [ -e \"$dest\" ]; do dest=\"${baseDest%.*}_$i\"; case \"$baseDest\" in *.*) ext=\".${baseDest##*.}\"; base=\"${baseDest%.*}\"; dest=\"${base}_$i$ext\";; esac; i=$((i+1)); done; gio copy -- \"$src\" \"$dest\" 2>/dev/null || cp -a -- \"$src\" \"$dest\" 2>/dev/null; ec=$?; if [ $ec -eq 0 ]; then echo COPIED:$dest; else echo FAIL; fi"
        }
        pasteProc.command = ["bash","-lc", cmd]
        pasteProc.running = true
        // Clear cut after move
        if (op === "cut") { clipboardPath = ""; clipboardOp = "" }
    }
    Process {
        id: pasteProc
        stdout: StdioCollector { id: pasteOutput; waitForEnd: true }
        onExited: function(code){
            var out = String(pasteOutput.text||"").trim()
            if (out.indexOf("COPIED:")===0 || out.indexOf("MOVED:")===0) {
                var created = out.split(":")[1]
                if (created) bumpFrecency(created)
                refreshDir()
                // Stay open? Spec says disappear after, but for paste we might want to stay to show result
                // We'll refresh and keep overlay open briefly, then dismiss? For now dismiss to follow spec
                // root.dismiss() — but keep open to show pasted file? We'll keep open and rebuild
                if (root.opened && !openWithMode) rebuildDisplay()
            } else if (out.indexOf("EXISTS:")===0) {
                // Could show feedback — for now just refresh
                refreshDir()
            } else if (out==="NOCLIP" || out.indexOf("NOTFOUND")===0) {
                // No clipboard — try to show message via displayModel? Keep as is
            }
            // Dismiss after paste per spec
            // root.dismiss()
        }
    }
    function revealInFileManager(path) {
        var p = String(path||"")
        if (!p) return
        var dir = p
        var cmd = "if [ -d " + Util.shellQuote(p) + " ]; then xdg-open " + Util.shellQuote(p) + " >/dev/null 2>&1 & elif command -v nautilus >/dev/null 2>&1; then nautilus --select " + Util.shellQuote(p) + " >/dev/null 2>&1 & else xdg-open " + Util.shellQuote(Fuzzy.dirname(p)) + " >/dev/null 2>&1 & fi"
        Util.execDetached(cmd)
        bumpFrecency(p)
        root.dismiss()
    }
    function openTerminalHere(path, isDirHint) {
        var p = String(path||"")
        var targetDir = p
        var isDir = typeof isDirHint === "boolean" ? isDirHint : (p && p.charAt(p.length-1) === "/")
        if (isDir) {
            targetDir = normalizeDir(p)
        } else if (p && p.charAt(p.length-1) !== "/" ) {
            targetDir = Fuzzy.dirname(p)
            if (!targetDir || targetDir===".") targetDir = currentDir
        } else {
            targetDir = normalizeDir(p)
        }
        if (!targetDir) targetDir = currentDir
        bumpFrecency(targetDir + "/")
        var cmd = "dir=" + Util.shellQuote(targetDir) + "; "
        cmd += "if command -v xdg-terminal-exec >/dev/null 2>&1; then "
        cmd += "  if command -v uwsm-app >/dev/null 2>&1; then uwsm-app -- xdg-terminal-exec --dir=\"$dir\" >/dev/null 2>&1 & "
        cmd += "  else xdg-terminal-exec --dir=\"$dir\" >/dev/null 2>&1 & fi; "
        cmd += "elif command -v foot >/dev/null 2>&1; then foot -D \"$dir\" >/dev/null 2>&1 & "
        cmd += "elif command -v alacritty >/dev/null 2>&1; then alacritty --working-directory \"$dir\" >/dev/null 2>&1 & "
        cmd += "elif command -v kitty >/dev/null 2>&1; then kitty --directory \"$dir\" >/dev/null 2>&1 & "
        cmd += "elif command -v ghostty >/dev/null 2>&1; then ghostty --working-directory=\"$dir\" >/dev/null 2>&1 & "
        cmd += "else xdg-open \"$dir\" >/dev/null 2>&1 & fi"
        Util.execDetached(cmd)
        root.dismiss()
    }
    function trashItem(path) {
        var p = String(path||"")
        if (!p) return
        // No rm -rf fallback — the confirm dialog promises "Recoverable in Trash",
        // so a missing trash tool must fail safe, not delete permanently.
        var cmd = "gio trash " + Util.shellQuote(p) + " 2>/dev/null || trash-put " + Util.shellQuote(p) + " 2>/dev/null"
        Util.execDetached(cmd)
        trashRefreshTimer.restart()
        root.dismiss()
    }
    Timer { id: trashRefreshTimer; interval: 500; onTriggered: refreshDir() }

    function requestTrashWithConfirm(path) {
        var p = String(path||"")
        if (!p) return
        // Avoid confirming for placeholder entries
        if (p === "" || p.indexOf("Loading") === 0 || p.indexOf("No ") === 0) return
        var name = Fuzzy.basename(p)
        // For folders, basename may be empty if path ends with /, handle
        if (!name || name === "/") name = p
        trashTarget = { path: p, name: name }
        trashConfirm.selectedIndex = 1
        trashConfirmOpen = true
    }
    function cancelTrashConfirm() {
        trashConfirmOpen = false
        trashTarget = null
        trashConfirm.selectedIndex = 1
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
    }
    function confirmTrash() {
        var t = trashTarget
        trashConfirmOpen = false
        trashTarget = null
        if (!t || !t.path) return
        // Show that it's recoverable — actual trash, not rm
        trashItem(t.path)
    }
    function openHelp() { helpOpen = true }
    function closeHelp() { helpOpen = false; Qt.callLater(function(){ keyCatcher.forceActiveFocus() }) }
    function toggleHelp() { if (helpOpen) closeHelp(); else openHelp() }
    function requestRename() {
        if (renameOpen || helpOpen || trashConfirmOpen || openWithMode) return
        if (!cursorActive || displayModel.count===0) return
        var row = displayModel.get(selectedIndex)
        if (!row || !row.path) return
        var p = String(row.path||"")
        if (!p || p.indexOf("Loading")===0 || p.indexOf("No ")===0) return
        var isDir = !!row.isDir
        var baseName = row.name
        // display name includes trailing slash for dirs — strip for edit
        if (isDir && baseName.charAt(baseName.length-1)==="/") baseName = baseName.slice(0,-1)
        if (!baseName) baseName = Fuzzy.basename(p)
        if (isDir && baseName.charAt(baseName.length-1)==="/") baseName = baseName.slice(0,-1)
        renameTarget = { path: p, name: baseName, isDir: isDir }
        renameText = baseName
        renameError = ""
        renameSelected = 1
        renameOpen = true
        Qt.callLater(function(){ if (renameInput) { renameInput.forceActiveFocus(); renameInput.selectAll() } })
    }
    function cancelRename() {
        renameOpen = false
        renameTarget = null
        renameError = ""
        renameSelected = 1
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
    }
    function confirmRename() {
        var t = renameTarget
        if (!t || !t.path) return
        var newName = String(renameText||"").trim()
        if (!newName) { renameError = "Name cannot be empty"; return }
        if (newName.indexOf("/")!==-1) { renameError = "Name cannot contain '/'"; return }
        if (newName === t.name) { cancelRename(); return }
        var dir = Fuzzy.dirname(t.path)
        if (!dir || dir==="." ) dir = currentDir
        dir = normalizeDir(dir)
        var newPath = joinPath(dir, newName)
        if (t.isDir) newPath += "/"
        // Normalize for existence check — trim trailing slash for test
        var checkPath = newPath
        if (checkPath.charAt(checkPath.length-1)==="/") checkPath = checkPath.slice(0,-1)
        if (!checkPath) checkPath = newPath
        renameError = ""
        // Async existence + move via renameProc
        var cmd = "old=" + Util.shellQuote(t.path) + "; new=" + Util.shellQuote(newPath) + "; check=" + Util.shellQuote(checkPath) + "; "
        cmd += "if [ -e \"$check\" ]; then echo EXISTS; exit 0; fi; "
        // Try gio move first, fallback to mv
        cmd += "gio move -- \"$old\" \"$new\" 2>/dev/null && echo MOVED:$new && exit 0; "
        cmd += "mv -- \"$old\" \"$new\" 2>/dev/null && echo MOVED:$new && exit 0; "
        cmd += "echo FAIL"
        renameProc.command = ["bash","-lc", cmd]
        renameProc.running = true
    }

    function createFolder() {
        var base = currentDir
        var name = "New Folder"
        var cmd = "base=" + Util.shellQuote(base) + "; name=" + Util.shellQuote(name) + "; i=1; target=\"$base/$name\"; while [ -e \"$target\" ]; do target=\"$base/$name $i\"; i=$((i+1)); done; mkdir -p \"$target\" && echo \"$target\""
        createFolderProc.command = ["bash","-lc", cmd]
        createFolderProc.running = true
    }
    Process {
        id: createFolderProc
        stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
            var created = String(text||"").trim()
            if (created) {
                bumpFrecency(created + "/")
                refreshDir()
            }
        } }
    }

    Process {
        id: renameProc
        stdout: StdioCollector { id: renameOutput; waitForEnd: true }
        onExited: function(code){
            var out = String(renameOutput.text||"").trim()
            if (out === "EXISTS") {
                renameError = "An item with that name already exists"
                Qt.callLater(function(){ if (renameInput) { renameInput.forceActiveFocus(); renameInput.selectAll() } })
                return
            }
            if (out.indexOf("MOVED:")===0) {
                var created = out.slice(6)
                var t = renameTarget
                renameOpen = false
                renameTarget = null
                renameError = ""
                if (created) bumpFrecency(created)
                saveState()
                refreshDir()
                // Stay open — select the renamed entry once the list rebuilds
                if (created) pendingRenameSelect = created
                return
            }
            // FAIL
            renameError = "Rename failed"
        }
    }
    property string pendingRenameSelect: ""

    // ---- Open With ----
    function enterOpenWithMode(path) {
        var p = String(path||"")
        if (!p) return
        openWithFile = p
        openWithMode = true
        filterText = ""
        selectedIndex = 0
        cursorActive = true
        if (searchProc.running) searchProc.running = false
        searchDebounce.stop()
        isSearching = false
        // Determine mime for filtering — use extension map, fallback to gio if needed
        var isDir = p.charAt(p.length-1) === "/" || false
        // Try to infer isDir via dirEntries if available
        for (var di=0; di<dirEntries.length; di++) if (dirEntries[di].path === p) { isDir = dirEntries[di].isDir; break }
        openWithMime = mimeForPath(p, isDir)
        // For folders, ensure we include known editors even if not in mime DB
        openWithRecommendedIds = []
        openWithAllIds = []
        // Async fetch recommended/all ids via gio mime — will call rebuildAppDisplay on exit
        var mtypeQ = Util.shellQuote(openWithMime)
        var cmd = "mtype=" + mtypeQ + "; "
        cmd += "echo \"__MIME__$mtype\"; "
        // Recommended from gio mime
        cmd += "gio mime \"$mtype\" 2>/dev/null | grep -oE \"[^[:space:]]+\\.desktop\" | sort -u | head -n 30; "
        // For folders, add known editors as recommended too
        cmd += "if [ \"$mtype\" = \"inode/directory\" ]; then for id in org.gnome.Nautilus.desktop code.desktop dev.zed.Zed.desktop nvim.desktop org.gnome.TextEditor.desktop codium.desktop; do echo \"$id\"; done | sort -u; fi; "
        cmd += "echo \"__ALL__\"; "
        cmd += "grep -l \"MimeType=.*$mtype\" /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop 2>/dev/null | xargs -r -I {} basename {} 2>/dev/null | sort -u | head -n 50; "
        // Also add folder handlers to all for completeness
        cmd += "if [ \"$mtype\" = \"inode/directory\" ]; then for id in org.gnome.Nautilus.desktop code.desktop dev.zed.Zed.desktop nvim.desktop org.gnome.TextEditor.desktop codium.desktop; do echo \"$id\"; done | sort -u; fi"
        openWithAppsProc.command = ["bash","-lc", cmd]
        openWithAppsProc.running = true
        // Show loading immediately
        displayModel.clear()
        displayModel.append({name:"Loading apps for " + openWithMime + "…", path:"", isDir:false, detail:"", hidden:false, iconName: "system-search", appIcon: "", appId: ""})
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
    }
    Process {
        id: openWithAppsProc
        stdout: StdioCollector { id: openWithAppsOutput; waitForEnd: true }
        onExited: function(code){
            var raw = String(openWithAppsOutput.text||"")
            var lines = raw.split("\n")
            var mode = "rec"
            var rec = [], all = []
            var seenRec = {}, seenAll = {}
            for (var i=0;i<lines.length;i++) {
                var l = String(lines[i]||"").trim()
                if (!l) continue
                if (l.indexOf("__MIME__")===0) continue
                if (l === "__ALL__") { mode = "all"; continue }
                if (l.indexOf(".desktop")===-1) continue
                // Normalize to end with .desktop
                if (l.slice(-8) !== ".desktop") l = l + ".desktop"
                if (mode === "rec") {
                    if (!seenRec[l]) { rec.push(l); seenRec[l]=true; if (!seenAll[l]) { all.push(l); seenAll[l]=true } }
                } else {
                    if (!seenAll[l]) { all.push(l); seenAll[l]=true }
                }
            }
            openWithRecommendedIds = rec
            openWithAllIds = all
            rebuildAppDisplay()
        }
    }
    function exitOpenWithMode() {
        openWithMode = false
        openWithFile = ""
        filterText = ""
        selectedIndex = 0
        rebuildDisplay()
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
    }
    function rebuildAppDisplay() {
        displayModel.clear()
        var lib = appLibrary || (shell && shell.appLibrary ? shell.appLibrary : null)
        // Build recommended set early for fallback path as well
        var recSetEarly = {}
        var hasRecEarly = false
        if (openWithMode && openWithMime !== "" && openWithRecommendedIds.length > 0) {
            hasRecEarly = true
            for (var re=0; re<openWithRecommendedIds.length; re++) {
                var ridE = String(openWithRecommendedIds[re]||"")
                if (ridE.slice(-8) !== ".desktop") ridE += ".desktop"
                recSetEarly[ridE] = true; recSetEarly[ridE.slice(0,-8)] = true
                recSetEarly[String(openWithRecommendedIds[re]||"")] = true
            }
        }
        if (!lib) {
            // Fallback: directly use recommendedIds to build display (avoids 61->5 filtering confusion)
            if (hasRecEarly && openWithRecommendedIds.length > 0) {
                var q2b = String(filterText||"").trim().toLowerCase();
                var directFiltered = [];
                for (var di2=0; di2<openWithRecommendedIds.length; di2++) {
                    var did2 = String(openWithRecommendedIds[di2]||"");
                    if (!did2) continue;
                    var found = null;
                    try {
                        if (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) {
                            var vals2 = DesktopEntries.applications.values || [];
                            for (var vi2=0; vi2<vals2.length; vi2++) {
                                var de2 = vals2[vi2];
                                var iid2 = String(de2.id||"");
                                if (iid2 === did2 || iid2 + ".desktop" === did2 || iid2 === did2.slice(0,-8)) { found = de2; break; }
                            }
                        }
                    } catch(e2) {}
                    var label2 = found ? String(found.name||did2) : did2;
                    var icon2 = found ? String(found.icon||did2) : did2;
                    var detail2 = found ? String(found.comment||did2) : did2;
                    if (q2b && label2.toLowerCase().indexOf(q2b)===-1 && did2.toLowerCase().indexOf(q2b)===-1) {
                        if (Fuzzy.fuzzyScore(q2b, label2) < 0 && Fuzzy.fuzzyScore(q2b, did2) < 0) continue;
                    }
                    directFiltered.push({id: did2, label: label2, icon: icon2, detail: detail2, entry: found});
                }
                directFiltered.sort(function(a,b){ return String(a.label).localeCompare(String(b.label)); });
                for (var fi3=0; fi3<Math.min(directFiltered.length,100); fi3++) {
                    var df = directFiltered[fi3];
                    displayModel.append({
                        name: df.label,
                        path: df.id,
                        isDir: false,
                        detail: df.detail,
                        hidden: false,
                        appIcon: df.icon,
                        appId: df.id,
                        iconName: ""
                    })
                }
                if (displayModel.count>0) { selectedIndex=0; cursorActive=true; layoutSerial++; Qt.callLater(function(){ resultList.positionViewAtIndex(0, ListView.Contain); }); return; }
            }
            // Fallback to showing filtered via DesktopEntries if direct failed
            try {
                if (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) {
                    var vals = DesktopEntries.applications.values || [];
                    if (vals.length > 0) {
                        var q2 = String(filterText||"").trim().toLowerCase();
                        var filtered = [];
                        for (var vi=0; vi<vals.length; vi++) {
                            var de = vals[vi];
                            var id = String(de.id||"");
                            var withExt = id.slice(-8) === ".desktop" ? id : id + ".desktop";
                            var withoutExt = id.slice(-8) === ".desktop" ? id.slice(0,-8) : id;
                            if (hasRecEarly && !recSetEarly[withExt] && !recSetEarly[withoutExt] && !recSetEarly[id]) continue;
                            var name = String(de.name||id);
                            if (q2 && name.toLowerCase().indexOf(q2)===-1 && id.toLowerCase().indexOf(q2)===-1) {
                                if (Fuzzy.fuzzyScore(q2, name) < 0 && Fuzzy.fuzzyScore(q2, id) < 0) continue;
                            }
                            filtered.push({entry: de, label: name});
                        }
                        filtered.sort(function(a,b){ return String(a.label).localeCompare(String(b.label)); });
                        for (var fi2=0; fi2<Math.min(filtered.length,100); fi2++) {
                            var fe = filtered[fi2].entry;
                            var _aicon = String(fe.icon||"");
                            displayModel.append({
                                name: String(fe.name||fe.id||""),
                                path: String(fe.id||""),
                                isDir: false,
                                detail: String(fe.comment||fe.id||""),
                                hidden: false,
                                appIcon: _aicon,
                                appId: String(fe.id||"")
                            , iconName: ""});
                        }
                        if (displayModel.count>0) { selectedIndex=0; cursorActive=true; layoutSerial++; Qt.callLater(function(){ resultList.positionViewAtIndex(0, ListView.Contain); }); return; }
                    }
                }
            } catch(e) {}
            displayModel.append({name:"No apps found", path:"", isDir:false, detail:"AppLibrary not available" + (shell ? " (shell ok, lib null)" : " (shell null)"), hidden:false});
            console.warn("Omafinder: appLibrary unavailable — shell=" + (shell ? "present" : "null") + " appLibrary prop=" + appLibrary);
            return;
        }
        var q = String(filterText||"").trim().toLowerCase()
        // Strict mime filtering: when in Open With, only show handlers for that mime (recommended + all for type)
        // If we are still loading (proc running and no ids yet), keep loading display
        if (openWithMode && openWithMime !== "" && openWithAllIds.length === 0 && openWithAppsProc.running) {
            return // keep "Loading…" shown by enterOpenWithMode
        }
        var mimeFilterActive = openWithMode && openWithMime !== ""
        // If strict but no handlers found, show no apps (not all)
        if (mimeFilterActive && openWithAllIds.length === 0) {
            displayModel.clear()
            displayModel.append({name:"No handlers for “" + openWithMime + "”", path:"", isDir:false, detail:"No apps declare support for this file type", hidden:false, iconName: "dialog-information", appIcon: "", appId: ""})
            selectedIndex=0; cursorActive=false; layoutSerial++; return
        }
        var recommendedSet = {}
        var allSet = {}
        if (mimeFilterActive) {
            for (var ri=0; ri<openWithRecommendedIds.length; ri++) {
                var rid = String(openWithRecommendedIds[ri]||"")
                if (rid.slice(-8) !== ".desktop") rid += ".desktop"
                recommendedSet[rid] = true
                allSet[rid] = true
                // also without extension
                recommendedSet[rid.slice(0,-8)] = true
                allSet[rid.slice(0,-8)] = true
            }
            for (var ai=0; ai<openWithAllIds.length; ai++) {
                var aid = String(openWithAllIds[ai]||"")
                if (aid.slice(-8) !== ".desktop") aid += ".desktop"
                allSet[aid] = true
                allSet[aid.slice(0,-8)] = true
            }
        }
        var entries
        try { entries = lib.sortedEntries(q) } catch(e) { entries = [] }
        // Recommended-only filtering: only show apps in recommendedSet (gio mime)
        var candidates = []
        for (var i=0; i<entries.length; i++) {
            var e = entries[i].entry
            if (!e || !e.id) continue
            var idStr = String(e.id||"")
            // Mime filtering: only keep apps in Recommended (strict)
            if (mimeFilterActive) {
                var withExt = idStr.slice(-8) === ".desktop" ? idStr : idStr + ".desktop"
                var withoutExt = idStr.slice(-8) === ".desktop" ? idStr.slice(0,-8) : idStr
                if (!recommendedSet[withExt] && !recommendedSet[withoutExt] && !recommendedSet[idStr]) continue
            }
            var label
            try { label = lib.entryName(e) } catch(ee) { label = String(e.id||"") }
            var detail
            try { detail = lib.entrySubtext(e) || String(e.id||"") } catch(ee2) { detail = String(e.id||"") }
            if (q && label.toLowerCase().indexOf(q)===-1 && detail.toLowerCase().indexOf(q)===-1) {
                if (Fuzzy.fuzzyScore(q, label) < 0 && Fuzzy.fuzzyScore(q, detail) < 0) continue
            }
            var score = 0
            // Recommended already filtered, no extra boost needed but keep for sorting
            if (q) score += Math.max(0, Fuzzy.fuzzyScore(q, label))
            candidates.push({entry: e, label: label, detail: detail, score: score})
        }
        candidates.sort(function(a,b){
            if (b.score !== a.score) return b.score - a.score
            return String(a.label).localeCompare(String(b.label))
        })
        var limit = 100
        var added = 0
        for (var ci=0; ci<candidates.length && added < limit; ci++) {
            var c = candidates[ci]
            var e2 = c.entry
            displayModel.append({
                name: c.label,
                path: String(e2.id||""),
                isDir: false,
                detail: c.detail,
                hidden: false,
                appIcon: String(e2.icon||""),
                appId: String(e2.id||"")
            , iconName: ""})
            added++
        }
        if (displayModel.count===0) {
            displayModel.append({name:"No apps for “" + filterText + "”", path:"", isDir:false, detail:"", hidden:false})
            selectedIndex=0; cursorActive=false
        } else {
            selectedIndex=0; cursorActive=true
        }
        layoutSerial++
        Qt.callLater(function(){ if (displayModel.count>0) resultList.positionViewAtIndex(selectedIndex, ListView.Contain) })
    }
    function launchAppWithFile(desktopId, filePath) {
        var did = String(desktopId||"").trim()
        var fp = String(filePath||"").trim()
        if (!did || !fp) {
            console.warn("Omafinder: launchAppWithFile missing args did=" + did + " fp=" + fp)
            return
        }
        if (did.slice(-8) === ".desktop") did = did.slice(0,-8)
        var desktopFile = did + ".desktop"
        bumpFrecency(fp)
        console.log("Omafinder: launching " + desktopFile + " with " + fp)
        var qDesktop = Util.shellQuote(desktopFile)
        var qFile = Util.shellQuote(fp)
        // Build a single bash chain without stray & before || — execDetached already backgrounds
        var cmd = ""
        cmd += "uwsm-app -- gtk-launch " + qDesktop + " " + qFile + " >/dev/null 2>&1; ec=$?; [ $ec -eq 0 ] && exit 0; "
        cmd += "gtk-launch " + qDesktop + " " + qFile + " >/dev/null 2>&1; ec=$?; [ $ec -eq 0 ] && exit 0; "
        // desktopFile is data — assign via single-quote so $/backticks in a crafted name stay literal
        cmd += "for d in /usr/share/applications /usr/local/share/applications $HOME/.local/share/applications; do p=$d/" + Util.shellQuote(desktopFile) + "; [ -f \"$p\" ] && { gio launch \"$p\" " + qFile + " >/dev/null 2>&1; ec=$?; [ $ec -eq 0 ] && exit 0; }; done; "
        cmd += "handlr launch --with=" + qDesktop + " " + qFile + " >/dev/null 2>&1; ec=$?; [ $ec -eq 0 ] && exit 0; "
        // Whole message is data — shellQuote keeps $(...) in a crafted filename from executing
        var failMsg = "Omafinder: launch failed for " + desktopFile + " with " + fp
        cmd += "echo " + Util.shellQuote(failMsg) + " >> /tmp/omafinder_launch.log 2>&1; exit 1"
        Util.execDetached(cmd)
        openWithMode = false
        openWithFile = ""
        root.dismiss()
    }

    function toggleHidden() {
        showHidden = !showHidden
        saveState()
        refreshDir()
        if (openWithMode) rebuildAppDisplay()
        else rebuildDisplay()
    }

    // ---- Models ----
    ListModel {
        id: displayModel
        // Explicit role definition via ListElement so delegate required properties always bind
        // Without this, first append defines roles and later appends with new roles (appIcon/appId) are ignored for recycled delegates
        ListElement { name: ""; path: ""; isDir: false; detail: ""; hidden: false; iconName: ""; appIcon: ""; appId: "" }
        Component.onCompleted: clear()
    }
    PointerMoveGate { id: pointerGate; referenceItem: card }

    // ---- UI ----
    PanelWindow {
        id: panel
        visible: root.opened
        anchors { top:true; bottom:true; left:true; right:true }
        color: "transparent"
        WlrLayershell.namespace: "omafinder"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        // Background scrim with fade
        Rectangle {
            id: scrimRect
            anchors.fill: parent
            color: root.scrim
            opacity: root.isAnimatingOut ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: root.isAnimatingOut ? root.animationDurationOut : root.animationDurationIn; easing.type: Easing.OutCubic } }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.dismiss()
        }

        BorderSurface {
            id: card
            width: root.cardWidth
            height: root.cardHeight
            radius: root.cornerRadius
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            // Slight slide/fade animation
            opacity: root.isAnimatingOut ? 0 : 1
            scale: root.isAnimatingOut ? 0.98 : 1.0
            Behavior on opacity { NumberAnimation { duration: root.isAnimatingOut ? root.animationDurationOut : root.animationDurationIn; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: root.isAnimatingOut ? root.animationDurationOut : root.animationDurationIn; easing.type: Easing.OutCubic } }
            color: root.background
            borderSpec: root.borderSpec
            padding: root.contentMargin

            MouseArea { anchors.fill: parent; onClicked: {} }

            Item {
                id: keyCatcher
                anchors.fill: parent
                z: (root.trashConfirmOpen || root.helpOpen || root.renameOpen) ? 20 : 0
                focus: true
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event){
                    // Rename dialog has top priority
                    if (renameOpen) {
                        if (event.key === Qt.Key_Escape) {
                            cancelRename(); event.accepted = true; return
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            confirmRename(); event.accepted = true; return
                        }
                        // Let the TextInput handle everything else (editing, selection)
                        return
                    }
                    // Help has top priority
                    if (helpOpen) {
                        if (event.key === Qt.Key_Escape || event.key === Qt.Key_F1 || event.key === Qt.Key_Question) {
                            closeHelp(); event.accepted = true; return
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            closeHelp(); event.accepted = true; return
                        } else if (event.key === Qt.Key_Slash && (event.modifiers & Qt.ControlModifier)) {
                            closeHelp(); event.accepted = true; return
                        } else if (event.key === Qt.Key_Up) {
                            helpFlickable.flick(0, 600); event.accepted = true; return
                        } else if (event.key === Qt.Key_Down) {
                            helpFlickable.flick(0, -600); event.accepted = true; return
                        } else if (event.key === Qt.Key_PageUp) {
                            helpFlickable.flick(0, 1200); event.accepted = true; return
                        } else if (event.key === Qt.Key_PageDown) {
                            helpFlickable.flick(0, -1200); event.accepted = true; return
                        } else if (event.key === Qt.Key_Home) {
                            helpFlickable.contentY = helpFlickable.originY; event.accepted = true; return
                        } else if (event.key === Qt.Key_End) {
                            helpFlickable.contentY = helpFlickable.originY + Math.max(0, helpFlickable.contentHeight - helpFlickable.height); event.accepted = true; return
                        }
                        event.accepted = true; return
                    }
                    // Trash confirm has priority
                    if (trashConfirmOpen) {
                        if (trashConfirm.handleKey(event)) event.accepted = true
                        return
                    }
                    // Help toggle — F1 or Ctrl+/ (also Ctrl+? via Question with Ctrl)
                    if (event.key === Qt.Key_F1
                        || (event.key === Qt.Key_Slash && (event.modifiers & Qt.ControlModifier))
                        || (event.key === Qt.Key_Question && (event.modifiers & Qt.ControlModifier))) {
                        toggleHelp(); event.accepted = true; return
                    }
                    // Rename — F2 on selected row
                    if (event.key === Qt.Key_F2) {
                        requestRename()
                        event.accepted = true
                        return
                    }
                    // Open With mode has its own handling
                    if (openWithMode) {
                        if (event.key === Qt.Key_Escape) {
                            exitOpenWithMode()
                            event.accepted = true
                            return
                        } else if (event.key === Qt.Key_Up) {
                            root.select(-1); event.accepted = true; return
                        } else if (event.key === Qt.Key_Down) {
                            root.select(1); event.accepted = true; return
                        } else if (event.key === Qt.Key_PageUp) {
                            root.select(-6); event.accepted = true; return
                        } else if (event.key === Qt.Key_PageDown) {
                            root.select(6); event.accepted = true; return
                        } else if (event.key === Qt.Key_Home) {
                            root.selectAbsolute(0); event.accepted = true; return
                        } else if (event.key === Qt.Key_End) {
                            root.selectAbsolute(displayModel.count-1); event.accepted = true; return
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (cursorActive && displayModel.count>0) {
                                var row = displayModel.get(selectedIndex)
                                if (row.path) launchAppWithFile(row.path, openWithFile)
                            }
                            event.accepted = true; return
                        } else if (Util.editsFilter(event, filterText)) {
                            setFilter(Util.editedFilter(event, filterText))
                            event.accepted = true; return
                        } else if (event.text && event.text.length===1 && event.text.charCodeAt(0)>=32 && event.text.charCodeAt(0)!==127 && (event.modifiers===Qt.NoModifier || event.modifiers===Qt.ShiftModifier)) {
                            setFilter(filterText + event.text)
                            event.accepted = true; return
                        } else if (event.key === Qt.Key_Backspace) {
                            if (Util.editsFilter(event, filterText)) { setFilter(Util.editedFilter(event, filterText)); event.accepted=true; return }
                            if (filterText) { setFilter(filterText.slice(0,-1)); event.accepted=true; return }
                        }
                        return
                    }
                    // Home: Ctrl+Shift+H
                    if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_H) {
                        navigateToDir(home)
                        event.accepted = true
                        return
                    }
                    // Hidden toggle: Ctrl+H (without Shift) or Ctrl+Dot
                    if ((event.modifiers & Qt.ControlModifier) && !(event.modifiers & Qt.ShiftModifier) && (event.key === Qt.Key_H || event.key === Qt.Key_Period)) {
                        root.toggleHidden()
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Escape) {
                        root.dismiss()
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_C) {
                        // Copy path (Ctrl+Shift+C) — swapped per request
                        if (displayModel.count>0 && cursorActive) {
                            var row = displayModel.get(selectedIndex)
                            root.copyPath(row.path)
                        } else if (filterText) {
                            root.copyPath(expandPath(filterText))
                        }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_C) {
                        // Copy file (uri-list) for paste (Ctrl+C) — stay open + go home for paste
                        if (displayModel.count>0 && cursorActive) {
                            var crow = displayModel.get(selectedIndex)
                            if (crow.path) copyFile(crow.path)
                        }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_X) {
                        // Cut file
                        if (displayModel.count>0 && cursorActive) {
                            var xrow = displayModel.get(selectedIndex)
                            if (xrow.path) cutFile(xrow.path)
                        }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_V) {
                        // Paste into current dir
                        pasteClipboard()
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_O) {
                        // Open With — now works for both files and folders (e.g., Zed on project dir)
                        if (displayModel.count>0 && cursorActive) {
                            var orow = displayModel.get(selectedIndex)
                            if (orow.path) enterOpenWithMode(orow.path)
                        } else if (!displayModel.count || !cursorActive) {
                            // No selection — try currentDir or filterText as folder
                            var fallback = currentDir
                            if (filterText && Fuzzy.isPathLike(filterText)) fallback = expandPath(filterText)
                            enterOpenWithMode(fallback)
                        }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_T) {
                        // Terminal here — cd into selected folder if folder, else its parent; currentDir if no selection
                        if (displayModel.count>0 && cursorActive) {
                            var r2 = displayModel.get(selectedIndex)
                            root.openTerminalHere(r2.path, r2.isDir)
                        } else root.openTerminalHere(currentDir, true)
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_O) {
                        // Reveal in file manager
                        if (displayModel.count>0 && cursorActive) {
                            var r3 = displayModel.get(selectedIndex)
                            root.revealInFileManager(r3.path)
                        }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
                        root.createFolder()
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_D) {
                        // Trash with confirm (Ctrl+D) — recoverable
                        if (displayModel.count>0 && cursorActive) {
                            var drow = displayModel.get(selectedIndex)
                            if (drow.path) requestTrashWithConfirm(drow.path)
                        }
                        event.accepted = true
                    } else if (event.key === Qt.Key_Delete) {
                        // Del routes through the same confirm — destructive keys never bypass the dialog
                        if (displayModel.count>0 && cursorActive) {
                            var delRow = displayModel.get(selectedIndex)
                            if (delRow.path) requestTrashWithConfirm(delRow.path)
                        }
                        event.accepted = true
                    } else if (event.key === Qt.Key_Backspace) {
                        // Handle parent navigation: if filter empty -> go back, with Alt -> always go back, with Ctrl -> word delete else normal char delete
                        if ((event.modifiers & Qt.AltModifier)) {
                            root.goBack()
                            event.accepted = true
                        } else if (!root.filterText) {
                            // empty -> go back (proposal: empty only)
                            root.goBack()
                            event.accepted = true
                        } else if (Util.editsFilter(event, root.filterText)) {
                            root.setFilter(Util.editedFilter(event, root.filterText))
                            event.accepted = true
                        } else {
                            // fallback: treat as goBack if still empty after? Already handled
                            root.setFilter(root.filterText.slice(0,-1))
                            event.accepted = true
                        }
                    } else if (Util.editsFilter(event, root.filterText)) {
                        root.setFilter(Util.editedFilter(event, root.filterText))
                        event.accepted = true
                    } else if (event.key === Qt.Key_Left && !root.filterText) {
                        root.goBack()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                        root.select(-1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down) {
                        root.select(1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_PageUp) {
                        root.select(-6)
                        event.accepted = true
                    } else if (event.key === Qt.Key_PageDown) {
                        root.select(6)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Home) {
                        root.selectAbsolute(0)
                        event.accepted = true
                    } else if (event.key === Qt.Key_End) {
                        root.selectAbsolute(displayModel.count-1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        // If filter is path-like and no selection? handle direct
                        if (root.filterText && Fuzzy.isPathLike(root.filterText)) {
                            root.handleEnterOnFilter()
                        } else if (root.cursorActive) {
                            root.activateIndex(root.selectedIndex)
                        } else if (displayModel.count>0) {
                            root.cursorActive=true
                        }
                        event.accepted = true
                    } else if (event.text && event.text.length===1 && event.text.charCodeAt(0)>=32 && event.text.charCodeAt(0)!==127 && (event.modifiers===Qt.NoModifier || event.modifiers===Qt.ShiftModifier)) {
                        root.setFilter(root.filterText + event.text)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Tab) {
                        event.accepted = true
                    }
                }

                ConfirmDialog {
                    id: trashConfirm
                    anchors.fill: parent
                    opened: trashConfirmOpen
                    z: 30
                    message: trashTarget ? ("Move “" + String(trashTarget.name||"") + "” to Trash?\nRecoverable in Trash.") : "Move to Trash?"
                    confirmText: "Move to Trash"
                    cancelText: "Cancel"
                    background: Color.menu.background
                    foreground: Color.menu.text
                    scrim: Util.alpha(Color.menu.background, 0.6)
                    selectedBackground: Color.menu.selectedBackground
                    selectedText: Color.menu.selectedText
                    fontFamily: root.fontFamily
                    cornerRadius: root.cornerRadius
                    onCanceled: cancelTrashConfirm()
                    onConfirmed: confirmTrash()
                }

                // Rename overlay — scrim + card with inline input and error
                Item {
                    id: renameOverlay
                    anchors.fill: parent
                    visible: renameOpen
                    z: 32

                    Rectangle {
                        anchors.fill: parent
                        color: Util.alpha(Color.menu.background, 0.65)
                        MouseArea { anchors.fill: parent; onClicked: cancelRename() }

                        BorderSurface {
                            id: renameCard
                            width: Math.min(parent.width - Style.space(32), Style.space(460))
                            height: renameCard.contentTopInset + renameCard.contentBottomInset + Style.space(18) + Style.space(10) + Style.space(40) + (renameError !== "" ? Style.space(20) : 0) + Style.space(10) + Style.space(34)
                            anchors.centerIn: parent
                            color: root.background
                            borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)
                            padding: Style.space(18)
                            radius: root.cornerRadius

                            MouseArea { anchors.fill: parent; onClicked: { if (renameInput) renameInput.forceActiveFocus() } }

                            Item {
                                anchors.fill: parent
                                anchors.topMargin: renameCard.contentTopInset
                                anchors.rightMargin: renameCard.contentRightInset
                                anchors.bottomMargin: renameCard.contentBottomInset
                                anchors.leftMargin: renameCard.contentLeftInset

                                Text {
                                    id: renameTitle
                                    textFormat: Text.PlainText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    text: "Rename"
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.title
                                }

                                Rectangle {
                                    id: renameField
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: renameTitle.bottom
                                    anchors.topMargin: Style.space(10)
                                    height: Style.space(40)
                                    radius: root.cornerRadius
                                    color: Qt.rgba(1,1,1,0.04)
                                    border.width: renameInput.activeFocus ? 1 : 0
                                    border.color: Util.alpha(root.selectedText, 0.6)

                                    TextInput {
                                        id: renameInput
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: Style.space(12)
                                        anchors.rightMargin: Style.space(12)
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: implicitHeight
                                        text: renameText
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        clip: true
                                        selectByMouse: true
                                        onTextEdited: root.renameText = text
                                        Keys.priority: Keys.BeforeItem
                                        Keys.onPressed: function(event) {
                                            if (event.key === Qt.Key_Escape) {
                                                cancelRename()
                                                event.accepted = true
                                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                                confirmRename()
                                                event.accepted = true
                                            }
                                        }
                                        Component.onCompleted: {
                                            if (renameOpen) { forceActiveFocus(); selectAll() }
                                        }
                                    }
                                }

                                Text {
                                    id: renameErrorText
                                    textFormat: Text.PlainText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: renameField.bottom
                                    anchors.topMargin: Style.space(6)
                                    text: renameError
                                    visible: renameError !== ""
                                    color: Color.urgent
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    elide: Text.ElideRight
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    spacing: Style.space(10)

                                    Repeater {
                                        model: ["Cancel", "Rename"]

                                        BorderSurface {
                                            required property int index
                                            required property string modelData

                                            readonly property bool selected: renameSelected === index
                                            readonly property bool destructive: index === 1

                                            width: Style.space(88)
                                            height: Style.space(34)
                                            color: selected
                                                ? (destructive ? Util.alpha(Color.urgent, 0.22) : root.selectedBackground)
                                                : "transparent"
                                            borderSpec: Border.flat(destructive
                                                ? (selected ? Color.urgent : Util.alpha(Color.urgent, 0.56))
                                                : (selected ? root.selectedText : Util.alpha(root.foreground, 0.38)), Style.normalBorderWidth)
                                            radius: 0

                                            Text {
                                                textFormat: Text.PlainText
                                                anchors.centerIn: parent
                                                text: modelData
                                                color: destructive ? (selected ? Color.urgent : root.foreground) : (selected ? root.selectedText : root.foreground)
                                                font.family: root.fontFamily
                                                font.pixelSize: Style.font.caption
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onEntered: renameSelected = index
                                                onClicked: {
                                                    if (index === 0) cancelRename()
                                                    else confirmRename()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Help overlay — scrim + card with scrollable keybinding reference
                Item {
                    id: helpOverlay
                    anchors.fill: parent
                    visible: helpOpen
                    z: 31

                    Rectangle {
                        anchors.fill: parent
                        color: Util.alpha(Color.menu.background, 0.65)
                        MouseArea { anchors.fill: parent; onClicked: closeHelp() }

                        BorderSurface {
                            id: helpCard
                            width: Math.min(parent.width - Style.space(32), Style.space(520))
                            height: Math.min(parent.height - Style.space(32), Style.space(560))
                            anchors.centerIn: parent
                            color: root.background
                            borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)
                            padding: Style.space(16)
                            radius: root.cornerRadius
                            MouseArea { anchors.fill: parent; onClicked: {} }

                            Item {
                                anchors.fill: parent
                                anchors.topMargin: helpCard.contentTopInset
                                anchors.rightMargin: helpCard.contentRightInset
                                anchors.bottomMargin: helpCard.contentBottomInset
                                anchors.leftMargin: helpCard.contentLeftInset

                                Column {
                                    anchors.fill: parent
                                    spacing: Style.space(10)

                                    Row {
                                        width: parent.width
                                        spacing: Style.space(8)
                                        Text {
                                            textFormat: Text.PlainText
                                            text: "Keybindings"
                                            color: root.foreground
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.font.title
                                            font.weight: Font.Medium
                                        }
                                        Item { width: Style.space(8); height: 1 }
                                        Text {
                                            textFormat: Text.PlainText
                                            text: "F1 / Ctrl+/ to close • Esc"
                                            color: root.foreground
                                            opacity: 0.45
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.font.caption
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.12) }

                                    Flickable {
                                        id: helpFlickable
                                        width: parent.width
                                        height: parent.height - Style.space(28) - Style.space(34) - Style.space(20) // title + divider + button + spacing
                                        contentHeight: helpContent.implicitHeight
                                        contentWidth: width
                                        clip: true
                                        flickableDirection: Flickable.VerticalFlick
                                        boundsBehavior: Flickable.StopAtBounds

                                        Column {
                                            id: helpContent
                                            width: parent.width
                                            spacing: Style.space(14)

                                            // Helper to render section — inlined as repeated Columns
                                            Column {
                                                width: parent.width
                                                spacing: Style.space(6)
                                                Text { textFormat: Text.PlainText; text: "Navigation"; color: root.foreground; opacity: 0.6; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                                                Column {
                                                    width: parent.width
                                                    spacing: 3
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "↑ / ↓  — Move selection"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "PgUp / PgDn  — Jump 6 rows"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Home / End  — First / Last"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "← (empty filter) / Backspace (empty) / Alt+Backspace  — Parent"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Enter  — Open file / Enter folder / Go to typed path"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Type  — Filter (≥2 chars global, <2 local, path-like direct)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Backspace / Ctrl+Backspace / Ctrl+U  — Delete char / word / clear filter"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                }
                                            }
                                            Column {
                                                width: parent.width
                                                spacing: Style.space(6)
                                                Text { textFormat: Text.PlainText; text: "File actions"; color: root.foreground; opacity: 0.6; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                                                Column {
                                                    width: parent.width
                                                    spacing: 3
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+C  — Copy file → stay, jump to ~ for paste"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+X  — Cut file → stay, jump to ~ for paste"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+V  — Paste into current folder"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+Shift+C  — Copy absolute path"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+D  — Trash (confirm)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Del  — Trash (opens the same confirm as Ctrl+D)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+N  — New folder"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "F2  — Rename (Enter confirm, Esc cancel, conflict errors in dialog)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+T  — Terminal here (folder → that folder, file → its dir)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+O  — Reveal in file manager"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+Shift+O  — Open With…"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                }
                                            }
                                            Column {
                                                width: parent.width
                                                spacing: Style.space(6)
                                                Text { textFormat: Text.PlainText; text: "View / Go"; color: root.foreground; opacity: 0.6; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                                                Column {
                                                    width: parent.width
                                                    spacing: 3
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+H / Ctrl+.  — Toggle hidden files"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Ctrl+Shift+H  — Go home (~)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Esc  — Back (Open With) / Close (browse)"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                }
                                            }
                                            Column {
                                                width: parent.width
                                                spacing: Style.space(6)
                                                Text { textFormat: Text.PlainText; text: "Open With mode"; color: root.foreground; opacity: 0.6; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                                                Column {
                                                    width: parent.width
                                                    spacing: 3
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Type  — Filter apps"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Enter  — Launch with file"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Esc  — Back to browse"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                }
                                            }
                                            Column {
                                                width: parent.width
                                                spacing: Style.space(6)
                                                Text { textFormat: Text.PlainText; text: "Dialogs"; color: root.foreground; opacity: 0.6; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                                                Column {
                                                    width: parent.width
                                                    spacing: 3
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Trash confirm:  ←/→/Tab switch, Enter confirm, Esc cancel, click scrim cancel — Del and Ctrl+D both open it"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                    Text { width: parent.width; textFormat: Text.PlainText; text: "Help:  Esc / Enter / F1 / Ctrl+/ close, click scrim close"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                                                }
                                            }
                                            Text { width: parent.width; textFormat: Text.PlainText; text: "Mouse: hover selects, click opens. Open With: click launches."; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
                                        }
                                    }

                                    Row {
                                        anchors.right: parent.right
                                        spacing: Style.space(10)
                                        BorderSurface {
                                            width: Style.space(88)
                                            height: Style.space(34)
                                            color: Util.alpha(Color.urgent, 0.10)
                                            borderSpec: Border.flat(Util.alpha(Color.urgent, 0.56), Style.normalBorderWidth)
                                            radius: 0
                                            Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: "Close"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: closeHelp() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Column {
                anchors.fill: parent
                anchors.topMargin: card.contentTopInset
                anchors.rightMargin: card.contentRightInset
                anchors.bottomMargin: card.contentBottomInset
                anchors.leftMargin: card.contentLeftInset
                spacing: root.contentSpacing

                // Header: location breadcrumb + input
                Column {
                    width: parent.width
                    spacing: Style.space(4)
                    // Breadcrumb
                    Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: openWithMode ? ("Open with: " + Fuzzy.basename(openWithFile)) : (tildeCollapse(currentDir) + (showHidden ? "" : "  • hidden hidden") + (isSearching ? "  • searching…" : "") + (clipboardPath ? "  • " + clipboardOp + ": " + Fuzzy.basename(clipboardPath) : ""))
                        color: root.foreground
                        opacity: 0.55
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                        visible: true
                    }
                    Rectangle {
                        width: parent.width
                        height: root.headerHeight
                        radius: root.cornerRadius
                        color: Qt.rgba(1,1,1,0.04)
                        border.width: 1
                        border.color: Util.alpha(root.foreground, 0.08)
                        // Input text
                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(12)
                            anchors.rightMargin: Style.space(12)
                            spacing: Style.space(8)
                            Text {
                                text: "›"
                                color: root.foreground
                                opacity: 0.5
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.heading
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Item {
                                width: parent.width - 24
                                height: parent.height
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                Text {
                                    id: inputText
                                    textFormat: Text.PlainText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.filterText ? root.filterText : (openWithMode ? "Search apps…" : "Search or type a path…")
                                    color: root.foreground
                                    opacity: root.filterText ? 1 : 0.38
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.heading
                                    elide: Text.ElideRight
                                }
                                Rectangle {
                                    id: cursorRect
                                    width: 2
                                    height: Style.font.heading * 1.1
                                    color: root.foreground
                                    opacity: 0.85
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: Math.min(inputText.paintedWidth + 4, parent.width - 6)
                                    visible: keyCatcher.activeFocus && root.filterText
                                    SequentialAnimation on opacity {
                                        loops: Animation.Infinite
                                        running: keyCatcher.activeFocus && root.filterText
                                        NumberAnimation { to: 0.2; duration: 600; easing.type: Easing.InOutQuad }
                                        NumberAnimation { to: 0.85; duration: 600; easing.type: Easing.InOutQuad }
                                    }
                                }
                            }
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: root.visibleRows * rowHeight + Math.max(0, root.visibleRows-1)*rowSpacing + 2
                    clip: true

                    ListView {
                        id: resultList
                        anchors.fill: parent
                        model: displayModel
                        clip: true
                        spacing: root.rowSpacing
                        boundsBehavior: Flickable.StopAtBounds
                        delegate: BorderSurface {
                            id: row
                            required property int index
                            required property string name
                            required property string path
                            required property bool isDir
                            required property string detail
                            required property bool hidden
                            required property string appIcon
                            required property string appId
                            required property string iconName
                            readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
                            readonly property bool isApp: openWithMode && appId !== ""
                            width: ListView.view.width
                            height: root.rowHeight
                            radius: root.cornerRadius
                            color: row.hasCursor ? root.selectedBackground : "transparent"
                            borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Style.space(10)
                                anchors.rightMargin: Style.space(10)
                                anchors.topMargin: Style.space(6)
                                anchors.bottomMargin: Style.space(6)
                                spacing: Style.space(10)

                                Component.onCompleted: {
                                    var _d = null;
                                    try { _d = displayModel.get(index); } catch(e) {}
                                }
                                // Icon — app icon when in Open With, else file icon via iconName, fallback to emoji
                                Image {
                                    id: appIconImage
                                    visible: row.isApp && row.appIcon !== ""
                                    width: Style.space(28)
                                    height: Style.space(28)
                                    source: {
                                        if (!visible) return "";
                                        var name = String(row.appIcon||"");
                                        if (!name) return "";
                                        if (name.indexOf("/") === 0 || name.indexOf("file://") === 0) return name.indexOf("file://")===0 ? name : Util.fileUrl(name);
                                        if (appLibrary) {
                                            try {
                                                var s = appLibrary.iconSource(name);
                                                if (s && String(s).length) return s;
                                            } catch(e) {}
                                        }
                                        var qp = Quickshell.iconPath(name, true);
                                        if (qp && String(qp).length) return qp;
                                        return Util.fileUrl("/usr/share/icons/hicolor/48x48/apps/" + name + ".png");
                                    }
                                    fillMode: Image.PreserveAspectFit
                                    sourceSize.width: width * Screen.devicePixelRatio
                                    sourceSize.height: height * Screen.devicePixelRatio
                                    asynchronous: true
                                    anchors.verticalCenter: parent.verticalCenter
                                    onStatusChanged: {
                                        if (status === Image.Error) {
                                            visible = false
                                        } else if (status === Image.Ready) {
                                            // console.log("Omafinder: appIcon OK " + row.appIcon)
                                        }
                                    }
                                }
                                Image {
                                    id: fileIconImage
                                    visible: !row.isApp && row.iconName !== ""
                                    width: Style.space(28)
                                    height: Style.space(28)
                                    source: visible ? Quickshell.iconPath(row.iconName, true) : ""
                                    fillMode: Image.PreserveAspectFit
                                    sourceSize.width: width * Screen.devicePixelRatio
                                    sourceSize.height: height * Screen.devicePixelRatio
                                    asynchronous: true
                                    anchors.verticalCenter: parent.verticalCenter
                                    onStatusChanged: if (status === Image.Error) visible = false
                                }
                                Text {
                                    visible: !appIconImage.visible && !fileIconImage.visible
                                    textFormat: Text.PlainText
                                    text: row.isDir ? "📁" : (row.hidden ? "·" : "📄")
                                    color: row.hasCursor ? root.selectedText : root.foreground
                                    opacity: row.isDir ? 0.9 : 0.7
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.iconLarge * 0.9
                                    width: visible ? Style.space(28) : 0
                                    horizontalAlignment: Text.AlignHCenter
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    width: parent.width - Style.space(28) - Style.space(10) - Style.space(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2
                                    Text {
                                        textFormat: Text.PlainText
                                        width: parent.width
                                        text: row.name
                                        color: row.hasCursor ? root.selectedText : root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        font.weight: row.isDir ? Font.Medium : Font.Normal
                                        elide: Text.ElideMiddle
                                        opacity: row.hidden ? 0.6 : 1.0
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        width: parent.width
                                        text: row.detail
                                        visible: row.detail && row.detail.length>0
                                        color: root.foreground
                                        opacity: row.hasCursor ? 0.7 : 0.45
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        elide: Text.ElideMiddle
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.selectFromPointer(row.index, row, {x: mouseX, y: mouseY})
                                onPositionChanged: function(mouse){ root.selectFromPointer(row.index, row, mouse) }
                                onClicked: {
                                    root.cursorActive=true
                                    root.selectedIndex=row.index
                                    if (openWithMode) {
                                        if (row.path) launchAppWithFile(row.path, openWithFile)
                                    } else {
                                        root.activateIndex(row.index)
                                    }
                                }
                                onPressAndHold: {
                                    if (openWithMode) return
                                    root.copyPath(row.path)
                                }
                            }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: Style.space(8)
                        visible: displayModel.count===0
                        Text {
                            text: root.filterText ? "∅" : "—"
                            color: root.foreground
                            opacity: 0.5
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.display
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: root.filterText ? "No results for “" + root.filterText + "”" : (dirEntries.length===0 ? "Empty folder" : "")
                            color: root.foreground
                            opacity: 0.6
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width
                        }
                    }
                }

                // Persistent footer — single, always visible (merged)
                Rectangle {
                    width: parent.width
                    height: Style.space(28)
                    radius: root.cornerRadius
                    color: "transparent"
                    Row {
                        anchors.centerIn: parent
                        spacing: Style.space(8)
                        visible: !openWithMode
                        Text { text: "Ctrl+D trash"; color: root.foreground; opacity: trashConfirmOpen ? 0.8 : 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
                        Text { text: "F2 rename"; color: root.foreground; opacity: renameOpen ? 0.85 : 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
                        Text { text: "Ctrl+Shift+C copy path"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
                        Text { text: "Ctrl+Shift+O open with"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
                        Text { text: "Ctrl+T term"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
                        Text { text: "F1 / Ctrl+/ help"; color: root.foreground; opacity: helpOpen ? 0.85 : 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.85 }
                    }
                    Row {
                        anchors.centerIn: parent
                        spacing: Style.space(10)
                        visible: openWithMode
                        Text { text: "↵ launch"; color: root.foreground; opacity: 0.55; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "⎋ back"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "type to filter apps"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "F1 help"; color: root.foreground; opacity: helpOpen ? 0.85 : 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.9 }
                    }
                }
            }
        }
    }
}