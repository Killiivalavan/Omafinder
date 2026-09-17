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
    property var globalPaths: []
    property bool globalIndexReady: false
    property bool globalIndexLoading: false
    property var dirEntries: [] // {name, path, isDir, hidden}
    property var frecency: ({})
    property string statePath: home + "/.local/state/omarchy/omafinder/state.json"
    property string stateDir: home + "/.local/state/omarchy/omafinder"
    property int animationDurationIn: 130
    property int animationDurationOut: 80
    property bool isAnimatingOut: false

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
        // Add a little for action hint bar
        total += Style.space(22)
        return Math.min(total, panel.height - Style.gapsOut*2)
    }

    // ---- Lifecycle ----
    function open(payloadJson) {
        var payload = {}
        try { payload = JSON.parse(payloadJson || "{}") } catch(e) { payload = {} }
        // Restore state if not yet loaded
        if (stateFile.text() && !stateLoaded) loadState(stateFile.text())
        if (!currentDir || currentDir === "") currentDir = home
        root.opened = true
        root.isAnimatingOut = false
        root.filterText = ""
        root.selectedIndex = 0
        root.cursorActive = true
        root.rebuildDisplay()
        refreshDir()
        ensureGlobalIndex()
        Qt.callLater(function(){ keyCatcher.forceActiveFocus() })
    }

    function close() {
        root.opened = false
        root.isAnimatingOut = false
    }

    function dismiss() {
        if (root.isAnimatingOut) return
        root.isAnimatingOut = true
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
        property string collected: ""
        stdout: SplitParser { onRead: function(line){ listProc.collected += line + "\n" } }
        stderr: StdioCollector { waitForEnd: true }
        onStarted: collected = ""
        onExited: function(code){
            var raw = collected
            var lines = String(raw||"").split("\n")
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
            if (root.opened) root.rebuildDisplay()
        }
    }

    // ---- Global index (fd) ----
    function ensureGlobalIndex() {
        if (globalIndexReady || globalIndexLoading) return
        // Only build if fd exists
        globalIndexLoading = true
        // Build index limited to HOME, include hidden, files + dirs, max 80k
        var cmd = ""
        cmd += "if ! command -v fd >/dev/null 2>&1; then find " + Util.shellQuote(home) + " -mindepth 1 \\( -type f -o -type d \\) -print 2>/dev/null | head -n 80000; exit 0; fi; "
        cmd += "fd -H -a --type f --type d . " + Util.shellQuote(home) + " 2>/devNull || fd -H -a --type f --type d . " + Util.shellQuote(home) + " 2>/dev/null | head -n 80000"
        // Note: use correct redirect — we handled typo above; fix fallback
        cmd = "if ! command -v fd >/dev/null 2>&1; then find " + Util.shellQuote(home) + " -mindepth 1 \\( -type f -o -type d \\) -print 2>/dev/null | head -n 80000; else fd -H -a --type f --type d . " + Util.shellQuote(home) + " 2>/dev/null | head -n 80000; fi"
        globalIndexProc.command = ["bash","-lc", cmd]
        globalIndexProc.running = true
    }

    Process {
        id: globalIndexProc
        property string collected: ""
        stdout: SplitParser { onRead: function(l){ globalIndexProc.collected += l + "\n" } }
        onStarted: collected = ""
        onExited: function(c){
            var lines = String(collected||"").split("\n")
            var out = []
            for (var i=0;i<lines.length;i++){
                var p = String(lines[i]||"").trim()
                if (!p) continue
                // fd with -a gives absolute? With . and home, it gives absolute? Ensure absolute
                // fd . $HOME produces relative? Actually fd . $HOME with base $HOME gives just names relative. We used fd . $HOME absolute? fd -a . $HOME with -a should be absolute.
                // If relative, prefix home
                if (p.charAt(0) !== "/") {
                    if (p.indexOf("./")===0) p = p.slice(2)
                    p = home + "/" + p
                }
                // quick dir detection: try to infer via trailing slash? fd doesn't append slash for dirs, but we can keep as is and later stat? For now keep path, infer isDir via filesystem? Leave isDir false, we will enhance later via stat if needed, but for search we don't need isDir immediately — we can lazy stat on activate.
                // To get isDir, we could have fd use - exec stat? Not needed now — we'll treat all as potential files and check on open.
                out.push(p)
            }
            // Also add directories themselves? fd already includes dirs.
            globalPaths = out
            globalIndexReady = true
            globalIndexLoading = false
            if (root.opened && root.filterText) root.rebuildDisplay()
            // debounce rebuild for browse frecency boost
            if (root.opened && !root.filterText) root.rebuildDisplay()
        }
    }

    // ---- Search / browse decision ----
    function rebuildDisplay() {
        displayModel.clear()
        var q = String(filterText||"").trim()
        var qLower = q.toLowerCase()

        // Path-like direct handling: if q looks like an absolute or ~ path and we can resolve its parent dir listing, show that.
        var isPathInput = Fuzzy.isPathLike(q) && q.length > 1
        // If q is exactly a dir path and exists, show its contents? But we don't know existence sync; we handle on Enter.
        // For live, if q contains '/', treat as path filter:
        if (isPathInput && q.indexOf('/') !== -1) {
            var expanded = expandPath(q)
            // Determine base dir and prefix
            var base = expanded
            var prefix = ""
            // If expanded ends with '/' then base is dir, prefix empty
            if (expanded.charAt(expanded.length-1) === "/") {
                base = expanded.slice(0,-1) || "/"
                prefix = ""
            } else {
                base = Fuzzy.dirname(expanded)
                prefix = Fuzzy.basename(expanded)
            }
            if (!base) base = "."
            base = normalizeDir(base)
            // Try to list base via sync? Instead, if base === currentDir, filter dirEntries
            // If base differs, we could run a one-off ls for base (async). For now, if base != currentDir, show filtered globalPaths that start with base?
            // Simple: if base exists in dirEntries parent, filter globalPaths for prefix.
            // We'll do: if base === currentDir, filter dirEntries by prefix
            if (base === currentDir) {
                var filtered = []
                for (var di=0; di<dirEntries.length; di++) {
                    var e = dirEntries[di]
                    if (prefix && e.name.toLowerCase().indexOf(prefix.toLowerCase()) !== 0) {
                        // also fuzzy within name?
                        if (Fuzzy.fuzzyScore(prefix, e.name) < 0) continue
                    }
                    filtered.push(e)
                }
                // Sort: dirs first, then frecency
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
                // Also if prefix empty, we already show all; if no results, show global path matches for expanded?
                if (displayModel.count===0) {
                    // fallback to global filter on expanded
                    var gfiltered = Fuzzy.scoreAndSort(globalPaths, expanded, 30)
                    for (var gi=0; gi<gfiltered.length; gi++) {
                        var gp = gfiltered[gi]
                        var isD = gp.charAt(gp.length-1) === "/"
                        displayModel.append({name: Fuzzy.basename(gp) + (isD?"/":""), path:gp, isDir:isD, detail: tildeCollapse(gp), hidden: isHiddenName(Fuzzy.basename(gp))})
                    }
                }
            } else {
                // Base is different directory — show a single row to navigate there + global matches
                // First row: go to base
                displayModel.append({name: Fuzzy.basename(base) + "/", path: normalizeDir(base) + "/", isDir:true, detail: tildeCollapse(normalizeDir(base)), hidden:false})
                // Then entries under base that match prefix via globalPaths
                var wantPrefix = base + "/" + prefix
                var matches = []
                for (var mi=0; mi<globalPaths.length; mi++) {
                    var mp = globalPaths[mi]
                    if (mp.indexOf(wantPrefix) === 0 || Fuzzy.fuzzyScore(q, mp) >=0) {
                        // only include those under base if prefix provided
                        if (prefix && mp.toLowerCase().indexOf(wantPrefix.toLowerCase())!==0) {
                            // check fuzzy inside
                            if (Fuzzy.fuzzyScore(prefix, Fuzzy.basename(mp))<0) continue
                            if (mp.indexOf(base) !== 0) continue
                        }
                        matches.push(mp)
                        if (matches.length>=80) break
                    }
                }
                // score sort for fuzzy
                var scored = []
                for (var si=0; si<matches.length; si++) scored.push({p:matches[si], s:Fuzzy.fuzzyScore(q, matches[si])})
                scored.sort(function(a,b){ return b.s - a.s })
                for (var sj=0; sj<scored.length && displayModel.count<100; sj++) {
                    var sp = scored[sj].p
                    var isDir2 = false
                    // heuristic: if path exists as dir in globalPaths with children, it's dir — but we treat all as file unless we know. We'll check via existence of any child.
                    // For now, treat as file/dir via stat not available; use trailing slash if originally dir? fd dirs not slash-terminated, so we can't know. We'll mark as dir if any other path starts with sp + "/"
                    for (var chk=0; chk<globalPaths.length; chk++) if (globalPaths[chk].indexOf(sp + "/")===0) { isDir2=true; break; }
                    if (isDir2 && sp.charAt(sp.length-1) !== "/") sp += "/"
                    displayModel.append({name: Fuzzy.basename(sp) + (isDir2?"/":""), path:sp, isDir:isDir2, detail: tildeCollapse(sp), hidden:isHiddenName(Fuzzy.basename(sp))})
                }
            }
            layoutSerial += 1
            if (displayModel.count>0) { selectedIndex = Math.min(selectedIndex, displayModel.count-1); cursorActive=true } else { selectedIndex=0; cursorActive=false }
            Qt.callLater(function(){ if (displayModel.count>0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
            return
        }

        if (!q) {
            // Browse mode
            var sorted = dirEntries.slice(0)
            // Sort dirs first, then frecency, then name
            sorted.sort(function(a,b){
                if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
                var sa = frecencyScore(a.path), sb = frecencyScore(b.path)
                if (Math.abs(sb-sa) > 0.1) return sb - sa
                // hidden last? but showHidden toggles visibility already
                return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
            })
            // If frecency has entries not in current dir, maybe inject top frequent within HOME? But spec says no dashboard — we keep it clean: only current dir + frecency boost.
            for (var bi=0; bi<sorted.length; bi++) {
                var be = sorted[bi]
                // respect hidden already
                displayModel.append({
                    name: be.name + (be.isDir?"/":""),
                    path: be.path,
                    isDir: be.isDir,
                    detail: be.isDir ? "" : tildeCollapse(be.path),
                    hidden: be.hidden
                })
            }
            // If empty dir, show parent hint? Not needed.
        } else {
            // Search mode: fuzzy across globalPaths + current dir entries
            var candidates = []
            // Add global paths scored
            var globalFiltered = Fuzzy.scoreAndSort(globalPaths, q, 120)
            // Also ensure current dir entries are included even if not in global index yet (new files)
            var currentPaths = []
            for (var ci=0; ci<dirEntries.length; ci++) currentPaths.push(dirEntries[ci].path)
            var combined = globalFiltered.slice(0)
            // Merge current dir not already in global filtered
            for (var cii=0; cii<currentPaths.length; cii++) {
                var cp = currentPaths[cii]
                if (combined.indexOf(cp)===-1 && Fuzzy.fuzzyScore(q, cp)>=0) combined.push(cp)
                if (combined.length>=150) break
            }
            // Score again with frecency boost
            var scoredAll = []
            for (var ai=0; ai<combined.length; ai++) {
                var ap = combined[ai]
                var baseScore = Fuzzy.fuzzyScore(q, ap)
                if (baseScore <0) continue
                var fScore = frecencyScore(ap)
                var total = baseScore + fScore
                // Boost if hidden and showHidden false? Actually filtered earlier? globalPaths includes hidden always, but we respect showHidden now:
                if (!showHidden && isHiddenName(Fuzzy.basename(ap))) continue
                scoredAll.push({path:ap, score:total})
            }
            // Also include dirEntries fuzzy for fresh entries not in globalPaths
            for (var di2=0; di2<dirEntries.length; di2++) {
                var de = dirEntries[di2]
                if (!showHidden && de.hidden) continue
                var already = false
                for (var sca=0; sca<scoredAll.length; sca++) if (scoredAll[sca].path === de.path) { already=true; break; }
                if (already) continue
                var s2 = Fuzzy.fuzzyScore(q, de.path)
                if (s2>=0) scoredAll.push({path:de.path, score:s2+frecencyScore(de.path)})
            }
            scoredAll.sort(function(a,b){
                if (b.score!==a.score) return b.score - a.score
                if (a.path.length!==b.path.length) return a.path.length - b.path.length
                return a.path.localeCompare(b.path)
            })
            var limit = 100
            for (var si2=0; si2<scoredAll.length && si2<limit; si2++) {
                var spath = scoredAll[si2].path
                // Determine isDir: check if any dirEntries knows, or global has children, or path ends with /
                var isDirFlag = spath.charAt(spath.length-1)==="/"
                if (!isDirFlag) {
                    for (var dk=0; dk<dirEntries.length; dk++) if (dirEntries[dk].path===spath) { isDirFlag=dirEntries[dk].isDir; break; }
                    if (!isDirFlag) {
                        for (var gk=0; gk<globalPaths.length; gk++) if (globalPaths[gk].indexOf(spath + "/")===0) { isDirFlag=true; break; }
                        // Also check via tilde? Not needed
                        // For files that are actually dirs but not yet known, we will lazy stat on open: but for display we guess.
                        // If still unknown, we could mark as dir if fs stat says? We'll leave as file and correct on activate via stat check.
                    }
                }
                var displayName = Fuzzy.basename(spath)
                if (isDirFlag) {
                    if (displayName==="") displayName = spath
                    displayName += "/"
                    if (spath.charAt(spath.length-1) !== "/") spath += "/"
                }
                var detail = tildeCollapse(spath)
                // For files, detail is parent dir; for dirs, detail is its own path? Show parent for both but dim
                // If search result is dir, show its path as detail; if file, show parent dir
                displayModel.append({
                    name: displayName,
                    path: spath,
                    isDir: isDirFlag,
                    detail: detail,
                    hidden: isHiddenName(Fuzzy.basename(spath))
                })
            }
            // If no results, show a hint row? Keep empty and show "No results"
        }

        layoutSerial += 1
        if (displayModel.count===0) { selectedIndex=0; cursorActive=false }
        else if (selectedIndex>=displayModel.count) { selectedIndex=displayModel.count-1; cursorActive=true }
        else if (selectedIndex<0) { selectedIndex=0; cursorActive=true }
        else if (!cursorActive && displayModel.count>0) { cursorActive=true }

        Qt.callLater(function(){ if (displayModel.count>0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
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
        // debounce search: rebuild immediately for browse, slight delay for global?
        root.rebuildDisplay()
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
        // Use wl-copy if available, fallback to xclip
        var cmd = "printf %s " + Util.shellQuote(p) + " | (command -v wl-copy >/dev/null 2>&1 && wl-copy || xclip -selection clipboard 2>/dev/null || true)"
        Util.execDetached(cmd)
        // bump frecency
        bumpFrecency(p)
        root.dismiss()
    }
    function copyFile(path) {
        var p = String(path||"")
        if (!p) return
        Util.execDetached("wl-copy --type text/uri-list -- " + Util.shellQuote("file://" + p) + " 2>/dev/null || true")
        bumpFrecency(p)
        root.dismiss()
    }
    function revealInFileManager(path) {
        var p = String(path||"")
        if (!p) return
        var dir = p
        // if file, reveal parent with select
        // try nautilus --select
        var cmd = "if [ -d " + Util.shellQuote(p) + " ]; then xdg-open " + Util.shellQuote(p) + " >/dev/null 2>&1 & elif command -v nautilus >/dev/null 2>&1; then nautilus --select " + Util.shellQuote(p) + " >/dev/null 2>&1 & else xdg-open " + Util.shellQuote(Fuzzy.dirname(p)) + " >/dev/null 2>&1 & fi"
        Util.execDetached(cmd)
        bumpFrecency(p)
        root.dismiss()
    }
    function openTerminalHere(path) {
        var p = String(path||"")
        var targetDir = p
        // if file, use its parent
        // we need to know if p is dir — heuristic: ends with /
        if (p && p.charAt(p.length-1) !== "/" ) {
            // assume file -> parent
            targetDir = Fuzzy.dirname(p)
            if (!targetDir || targetDir===".") targetDir = currentDir
        } else {
            targetDir = normalizeDir(p)
        }
        if (!targetDir) targetDir = currentDir
        bumpFrecency(targetDir + "/")
        // Try common terminals: omarchy default terminal via omarchy launch? Use xdg-terminal? Simplest: try foot, alacritty, kitty, ghostty
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
        // refresh after a moment
        trashRefreshTimer.restart()
        // don't dismiss? Spec says dismiss after action — trash should dismiss? We'll dismiss.
        root.dismiss()
    }
    Timer { id: trashRefreshTimer; interval: 500; onTriggered: refreshDir() }

    function createFolder() {
        var base = currentDir
        var name = "New Folder"
        // Find unused name
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
                // navigate into new folder? Just refresh and keep open
                // Optionally select it
            }
        } }
    }

    function toggleHidden() {
        showHidden = !showHidden
        saveState()
        refreshDir()
        rebuildDisplay()
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
                    // Hidden toggle: Ctrl+H or Ctrl+Dot
                    if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_H || event.key === Qt.Key_Period)) {
                        root.toggleHidden()
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Escape) {
                        if (root.filterText) { root.setFilter("") }
                        else { root.dismiss() }
                        event.accepted = true
                    } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_C) {
                        // Copy path of selected
                        if (displayModel.count>0 && cursorActive) {
                            var row = displayModel.get(selectedIndex)
                            root.copyPath(row.path)
                        } else if (filterText) {
                            root.copyPath(expandPath(filterText))
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
                            // If display has selection, prefer selection unless filter is exact path
                            // Check if filter exactly matches expanded path existence — let handleEnterOnFilter decide
                            // If cursorActive and selected row's path matches filter? Then activateIndex, else direct
                            // Simpler: if filter contains '/' and selected row not matching filter, try direct first then fallback
                            // We'll call handleEnterOnFilter which will prioritize direct path if exists
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
                        // Quick toggle hidden? Or cycle focus? Use Tab to toggle hidden for discovery
                        // Keep Tab for navigation? Not needed
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
                        text: tildeCollapse(currentDir) + (showHidden ? "" : "  • hidden hidden") + (globalIndexLoading ? "  • indexing…" : "")
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
                                    id: filterDisplay
                                    textFormat: Text.PlainText
                                    anchors.left: parent.left
                                    anchors.right: cursorRect.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.rightMargin: 2
                                    text: root.filterText
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.heading
                                    elide: Text.ElideRight
                                }
                                Text {
                                    anchors.fill: parent
                                    text: root.filterText ? "" : "Search or type a path…"
                                    color: root.foreground
                                    opacity: 0.38
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.heading
                                    elide: Text.ElideRight
                                    visible: !root.filterText
                                }
                                Rectangle {
                                    id: cursorRect
                                    width: 2
                                    height: parent.height * 0.55
                                    color: root.foreground
                                    opacity: 0.9
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: filterDisplay.contentWidth + 2
                                    visible: keyCatcher.activeFocus
                                    SequentialAnimation on opacity {
                                        loops: Animation.Infinite
                                        running: keyCatcher.activeFocus
                                        NumberAnimation { to: 0.2; duration: 600; easing.type: Easing.InOutQuad }
                                        NumberAnimation { to: 0.9; duration: 600; easing.type: Easing.InOutQuad }
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
                            readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
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

                                // Icon
                                Text {
                                    textFormat: Text.PlainText
                                    text: row.isDir ? "📁" : (row.hidden ? "·" : "📄")
                                    // Use text icons for simplicity; fallback to glyphs
                                    // For dirs, show folder; files show page
                                    color: row.hasCursor ? root.selectedText : root.foreground
                                    opacity: row.isDir ? 0.9 : 0.7
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.iconLarge * 0.9
                                    width: Style.space(28)
                                    horizontalAlignment: Text.AlignHCenter
                                    anchors.verticalCenter: parent.verticalCenter
                                    // Override with nicer glyphs if available
                                    // Use nerd font folder icon if rendered
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
                                    root.activateIndex(row.index)
                                }
                                // Right click for context? Show copy
                                onPressAndHold: {
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
                        spacing: Style.space(12)
                        Text { text: "↵ open"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "⌫ parent"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "⎋ close"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "Ctrl+H hidden"; color: root.foreground; opacity: showHidden ? 0.45 : 0.25; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "Ctrl+C copy"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                        Text { text: "Ctrl+T term"; color: root.foreground; opacity: 0.45; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    }
                }
            }
        }
    }
}
