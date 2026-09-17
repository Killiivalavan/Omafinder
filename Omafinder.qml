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
    property bool showHidden: true
    property bool showHiddenPersisted: true
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
        // Footer: 22 + 18 when not in Open With
        total += Style.space(22) + (openWithMode ? 0 : Style.space(18))
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
        if (searchProc.running) searchProc.running = false
        searchDebounce.stop()
        isSearching = false
    }

    function dismiss() {
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
                root.shell.hide(root.manifest ? root.manifest.id : "omafinder")
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
                showHiddenPersisted = data.showHidden
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
        // ensure dir exists
        stateSaveProc.command = ["bash","-lc", "mkdir -p " + Util.shellQuote(stateDir) + " && cat > " + Util.shellQuote(statePath)]
        stateSaveProc.input = JSON.stringify(payload, null, 2) + "\n"
        stateSaveProc.running = true
    }

    Process {
        id: stateSaveProc
        property string input: ""
        stdinEnabled: true
        onStarted: {
            try { write(input); closeWriteChannel() } catch(e) {}
        }
    }

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: false
        printErrors: false
        onLoaded: root.loadState(text())
        onLoadFailed: root.stateLoaded = true
    }

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
            if (root.opened) {
                // Only rebuild if not in search mode (filter empty or path-like)
                var q = String(filterText||"").trim()
                if (!q || (Fuzzy.isPathLike(q) && q.indexOf('/')!==-1)) root.rebuildDisplay()
                // If in search mode, keep search results; browsing entries are still updated for later
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
        displayModel.append({name:"Searching…", path:"", isDir:false, detail:"", hidden:false})
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
                    displayModel.append({name: fe.name + (fe.isDir?"/":""), path: fe.path, isDir: fe.isDir, detail: tildeCollapse(fe.path), hidden: fe.hidden})
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
                displayModel.append({name: dname, path: spath, isDir: isDirFlag, detail: tildeCollapse(spath), hidden: isHiddenName(Fuzzy.basename(spath))})
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
                        hidden: fe.hidden
                    })
                }
                if (displayModel.count===0 && !isSearching) {
                    displayModel.append({name:"No match", path:"", isDir:false, detail:"Try a different prefix or check hidden (Ctrl+H)", hidden:false})
                }
            } else {
                displayModel.append({name: Fuzzy.basename(base) + "/", path: normalizeDir(base) + "/", isDir:true, detail: tildeCollapse(normalizeDir(base)), hidden:false})
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
                    hidden: be.hidden
                })
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
                    displayModel.append({name: sfe.name + (sfe.isDir?"/":""), path: sfe.path, isDir: sfe.isDir, detail: tildeCollapse(sfe.path), hidden: sfe.hidden})
                }
                if (displayModel.count===0) displayModel.append({name:"No results", path:"", isDir:false, detail:'Type more characters for global search', hidden:false})
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
                    displayModel.append({name: lfe.name + (lfe.isDir?"/":""), path: lfe.path, isDir: lfe.isDir, detail: tildeCollapse(lfe.path), hidden: lfe.hidden})
                }
                // If no local results, trigger global search now (if not already)
                if (displayModel.count===0) {
                    pendingSearchQuery = q
                    searchDebounce.restart()
                    displayModel.clear()
                    displayModel.append({name:"Searching…", path:"", isDir:false, detail:"", hidden:false})
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

    function resolvePathInput(input) {
        var s = String(input||"").trim()
        if (!s) return ""
        var expanded = expandPath(s)
        return expanded
    }

    // Check if path is dir via stat (async) then act
    property string pendingActivatePath: ""
    property bool pendingActivateIsDir: false

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
        // Check if expanded path is absolute and exists as file/dir via quick test: we dispatch pending logic for expanded
        // We'll do stat for expanded first
        var testPath = expanded
        // If q contains no slash and not path-like, but user pressed enter on empty-ish? Use selected row
        if (!Fuzzy.isPathLike(q)) {
            if (displayModel.count>0 && cursorActive) activateIndex(selectedIndex)
            else {
                // Try expanded as file in currentDir
                var tryFile = joinPath(currentDir, q)
                pendingActivatePath = tryFile
                var cmd2 = "if [ -d " + Util.shellQuote(tryFile) + " ]; then echo DIR; elif [ -e " + Util.shellQuote(tryFile) + " ]; then echo FILE; elif [ -e " + Util.shellQuote(expanded) + " ]; then echo EXPANDED_FILE; else echo MISSING; fi"
                // ugly but handle: we will just check expanded via stat
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
        // Copy should keep overlay open briefly? Spec says dismiss after — keep dismiss
        root.dismiss()
    }
    function cutFile(path) {
        copyFileToClipboard(path, "cut")
        root.dismiss()
    }
    function pasteClipboard() {
        var src = String(clipboardPath||"")
        var op = String(clipboardOp||"copy")
        if (!src) {
            // Fallback: try to get uri-list from system clipboard via wl-paste
            // We do async paste via wl-paste, but for now just try to paste whatever is in system clipboard if our internal is empty
            // Use a helper process to read wl-paste and then do gio copy
            var pasteCmd = "src=$(wl-paste --type text/uri-list 2>/dev/null | head -n1 | sed 's/^file:\\/\\///' | sed 's/%20/ /g'); [ -z \"$src\" ] && src=$(wl-paste 2>/dev/null | head -n1); src=$(printf %s \"$src\" | tr -d '\\r\\n' | sed 's/^file:\\/\\///'); if [ -z \"$src\" ]; then echo NOCLIP; exit 0; fi; if [ ! -e \"$src\" ]; then echo NOTFOUND; exit 0; fi; dest=" + Util.shellQuote(currentDir) + "/$(basename -- \"$src\"); if [ -e \"$dest\" ]; then echo EXISTS; exit 0; fi; if [ \"" + op + "\" = \"cut\" ]; then gio move -- \"" + "\"$src\" \"$dest\" 2>/dev/null || mv -- \"$src\" \"$dest\" 2>/dev/null && echo MOVED || echo FAIL; else gio copy -- \"" + "\"$src\" \"$dest\" 2>/dev/null || cp -a -- \"$src\" \"$dest\" 2>/dev/null && echo COPIED || echo FAIL; fi"
            // Actually we need src inside command — simpler: just try pasteProc
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
    function openTerminalHere(path) {
        var p = String(path||"")
        var targetDir = p
        if (p && p.charAt(p.length-1) !== "/" ) {
            targetDir = Fuzzy.dirname(p)
            if (!targetDir || targetDir===".") targetDir = currentDir
        } else {
            targetDir = normalizeDir(p)
        }
        if (!targetDir) targetDir = currentDir
        bumpFrecency(targetDir + "/")
        var cmd = "dir=" + Util.shellQuote(targetDir) + "; "
        cmd += "if command -v omarchy >/dev/null 2>&1; then omarchy launch terminal --working-directory \"$dir\" >/dev/null 2>&1 & "
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
        var cmd = "gio trash " + Util.shellQuote(p) + " 2>/dev/null || trash-put " + Util.shellQuote(p) + " 2>/dev/null || rm -rf " + Util.shellQuote(p)
        Util.execDetached(cmd)
        trashRefreshTimer.restart()
        root.dismiss()
    }
    Timer { id: trashRefreshTimer; interval: 500; onTriggered: refreshDir() }

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

    // ---- Open With ----
    function enterOpenWithMode(path) {
        var p = String(path||"")
        if (!p) return
        // Check if it's a file (not dir)
        openWithFile = p
        openWithMode = true
        filterText = ""
        selectedIndex = 0
        cursorActive = true
        // Clear any pending search
        if (searchProc.running) searchProc.running = false
        searchDebounce.stop()
        isSearching = false
        rebuildAppDisplay()
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
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
        if (!appLibrary) {
            displayModel.append({name:"No apps found", path:"", isDir:false, detail:"AppLibrary not available", hidden:false})
            return
        }
        var q = String(filterText||"").trim().toLowerCase()
        var entries = appLibrary.sortedEntries(q) // already filtered/sorted by AppSearch
        // AppSearch already does fuzzy, but we add our own filter for consistency when q empty
        var limit = 100
        var added = 0
        for (var i=0; i<entries.length && added < limit; i++) {
            var e = entries[i].entry
            if (!e || !e.id) continue
            var label = appLibrary.entryName(e)
            var detail = appLibrary.entrySubtext(e) || String(e.id||"")
            // Additional fuzzy filter if needed (AppSearch already filtered, but keep)
            if (q && label.toLowerCase().indexOf(q)===-1 && detail.toLowerCase().indexOf(q)===-1) {
                if (Fuzzy.fuzzyScore(q, label) < 0 && Fuzzy.fuzzyScore(q, detail) < 0) continue
            }
            displayModel.append({
                name: label,
                path: String(e.id||""), // store desktopId in path
                isDir: false,
                detail: detail,
                hidden: false,
                appIcon: String(e.icon||""),
                appId: String(e.id||"")
            })
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
        if (!did || !fp) return
        // Normalize desktopId: remove .desktop suffix if present for gtk-launch
        if (did.slice(-8) === ".desktop") did = did.slice(0,-8)
        bumpFrecency(fp)
        // Launch via uwsm-app + gtk-launch, same as AppLibrary.launch but with file arg
        var cmd = "uwsm-app -- gtk-launch " + Util.shellQuote(did + ".desktop") + " " + Util.shellQuote(fp) + " >/dev/null 2>&1 &"
        // Fallback: try gio launch
        var fallback = "gio launch " + Util.shellQuote(did + ".desktop") + " " + Util.shellQuote(fp) + " >/dev/null 2>&1 &"
        Util.execDetached(cmd + " || " + fallback)
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
    ListModel { id: displayModel }
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
                focus: true
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event){
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
                    // Hidden toggle: Ctrl+H or Ctrl+Dot
                    if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_H || event.key === Qt.Key_Period)) {
                        root.toggleHidden()
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Escape) {
                        root.dismiss()
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_C) {
                        // Copy file (uri-list) for paste
                        if (displayModel.count>0 && cursorActive) {
                            var crow = displayModel.get(selectedIndex)
                            if (crow.path) copyFileToClipboard(crow.path, "copy")
                            // Keep copied path visible? Don't dismiss immediately? But spec says dismiss — we will keep clipboard and dismiss
                            root.dismiss()
                        }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_C) {
                        // Copy path of selected (Ctrl+C)
                        if (displayModel.count>0 && cursorActive) {
                            var row = displayModel.get(selectedIndex)
                            root.copyPath(row.path)
                        } else if (filterText) {
                            root.copyPath(expandPath(filterText))
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
                        // Open With
                        if (displayModel.count>0 && cursorActive) {
                            var orow = displayModel.get(selectedIndex)
                            if (orow.path && !orow.isDir) enterOpenWithMode(orow.path)
                        }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_T) {
                        // Terminal here
                        if (displayModel.count>0 && cursorActive) {
                            var r2 = displayModel.get(selectedIndex)
                            root.openTerminalHere(r2.path)
                        } else root.openTerminalHere(currentDir)
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
                    } else if (event.key === Qt.Key_Delete) {
                        if (displayModel.count>0 && cursorActive) {
                            var delRow = displayModel.get(selectedIndex)
                            root.trashItem(delRow.path)
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
                            property string appIcon: ""
                            property string appId: ""
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

                                // Icon — app icon when in Open With, else folder/file
                                Image {
                                    visible: row.isApp && row.appIcon !== ""
                                    width: Style.space(28)
                                    height: Style.space(28)
                                    source: visible && appLibrary ? appLibrary.iconSource(row.appIcon) : ""
                                    fillMode: Image.PreserveAspectFit
                                    sourceSize.width: width * Screen.devicePixelRatio
                                    sourceSize.height: height * Screen.devicePixelRatio
                                    asynchronous: true
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    visible: !row.isApp || row.appIcon === ""
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

                // Footer hints
                Rectangle {
                    width: parent.width
                    height: Style.space(22)
                    radius: root.cornerRadius
                    color: "transparent"
                    Row {
                        anchors.centerIn: parent
                        spacing: Style.space(10)
                        visible: !openWithMode
                        Text { text: "↵ open"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "⌫ parent"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "⎋ close"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "Ctrl+H hidden"; color: root.foreground; opacity: showHidden ? 0.45 : 0.25; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "Ctrl+C copy path"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "Ctrl+X cut"; color: root.foreground; opacity: clipboardOp==="cut" ? 0.7 : 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "Ctrl+V paste"; color: root.foreground; opacity: clipboardPath ? 0.65 : 0.25; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    }
                    Row {
                        anchors.centerIn: parent
                        spacing: Style.space(10)
                        visible: !openWithMode
                        // Second row for extra hints — shown as wrap if needed, keep single row for now with smaller spacing
                    }
                    Row {
                        anchors.centerIn: parent
                        spacing: Style.space(12)
                        visible: openWithMode
                        Text { text: "↵ launch"; color: root.foreground; opacity: 0.55; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "⎋ back"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "type to filter apps"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    }
                }
                // Second footer line for open-with / term hints (only when not in openWith)
                Rectangle {
                    width: parent.width
                    height: openWithMode ? 0 : Style.space(18)
                    visible: !openWithMode
                    color: "transparent"
                    Row {
                        anchors.centerIn: parent
                        spacing: Style.space(10)
                        Text { text: "Ctrl+Shift+C copy file"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.9 }
                        Text { text: "Ctrl+Shift+O open with"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.9 }
                        Text { text: "Ctrl+T term"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.9 }
                        Text { text: "Ctrl+O reveal"; color: root.foreground; opacity: 0.35; font.family: root.fontFamily; font.pixelSize: Style.font.caption * 0.9 }
                    }
                }
            }
        }
    }
}
