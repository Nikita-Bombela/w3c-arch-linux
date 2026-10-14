# Architecture

Flow charts of what `w3c-linux.sh` does and where it decides. Every decision node carries its planning ID, written as
`P<phase> D-<n>`. The diagrams are Mermaid, so GitHub, GitLab and most
editors render them inline; nothing needs to be installed.

Each chart stays small on purpose. Error exits that only print a message and return are drawn as one `stop` node, and
the shared helpers (`run_checks`, `wait_idle`, `ask`) are drawn as single boxes. Read the lib file for the details.

## Module map

```mermaid
flowchart LR
    entry["w3c-linux.sh<br/>version exit before anything (P7 D-07)<br/>finds lib/ next to itself, from a clone,<br/>a symlink or <prefix>/lib/w3c-linux (package or make)<br/>sources every lib file<br/>backend_resolve before the case (P10 D-06)<br/>case on $1 (no argument prints usage)"]

    subgraph cmds["one file per subcommand"]
        doctor[doctor.sh]
        install[install.sh]
        update[update.sh]
        revert[revert.sh]
        launch[launch.sh]
        monitor[monitor.sh]
        report[report.sh]
    end

    subgraph shared["shared code"]
        common["common.sh<br/>paths, say/emit, ask, state files, run lock fd 9<br/>install kind and OWN_DESK from SELF (P11 D-05, D-01)<br/>BIN_NAME: the command name hints print (P7 D-13, P11 D-06)"]
        faugus["faugus.sh<br/>faugus_backend: the only Faugus reader<br/>runner switch, Battle.net start, idle processes"]
        umu["umu.sh<br/>umu backend: backend_resolve, umu_backend,<br/>backend file and subcommand, umu cold start<br/>P10 D-06, D-16, D-17"]
        checks["checks.sh<br/>run_checks: the doctor rows"]
        proton["proton.sh<br/>release lookup, download, idle wait"]
        prefix["prefix.sh<br/>launcher status, WebView2, registry, MSI steps"]
        nat["nat.sh<br/>NAT rule text, offer, apply"]
        askpass["w3c-askpass.sh<br/>the password dialog for sudo -A<br/>P6 D-02"]
        share["share/<br/>the .desktop entry and icon<br/>a clone install copies them (P6 D-15),<br/>the package and make install them under <prefix>/share"]
    end

    py["w3c_helper.py<br/>python3 -I -B<br/>JSON parsers only (P1 D-10)"]

    faugus -->|"BACKEND=umu"| umu
    entry --> cmds
    cmds --> shared
    install --> nat
    nat -.->|"no terminal: SUDO_ASKPASS"| askpass
    install -.->|"entry and icon"| share
    launch -.->|"LAN hint"| nat
    launch -->|"mon_start"| monitor
    install -->|"Launch now?"| launch
    faugus & proton & prefix -->|"argv or stdin in,<br/>NUL-delimited fields out (P1 D-09)"| py
```

`packaging/PKGBUILD` runs `make install DESTDIR=... PREFIX=/usr`. The Makefile installs the clone layout under `<prefix>/lib/w3c-linux`
with `<prefix>/bin/w3c-linux` as a relative symlink (`make install-user` uses `~/.local`), so the same rule finds `lib/`.

State on disk, all under `~/.local/state/w3c-linux/`:

| File | Written by | Read by |
|---|---|---|
| `proton-tag` | install, update, revert | install, update, revert, doctor, launch |
| `proton-tag.prev` | update (P3 D-14), cleared by revert | revert, install and update removal offers |
| `launcher-version` | install, update (sync) | doctor, launch |
| `nat-applied` | NAT apply (P5 D-04) | install prompt 8, launch LAN hint |
| `matches.log` | monitor (P5 D-13) | you |
| `monitor.lock` | monitor (flock fd 8) | monitor |
| `*.json` backups | every runner switch (P2 D-18) | revert |

One file lives outside it: `~/.config/w3c-linux/backend` (`$XDG_CONFIG_HOME` is honoured), the umu backend's prefix and runner. `backend set`, `install` and `update` write it (P10 D-13, D-17); every command reads it through `backend_resolve`, and `backend clear` removes it.

## `install`: the questions

Everything is asked first, then the run is unattended (P3 D-01).

```mermaid
flowchart TD
    A([install]) --> B{"W3C_WEBVIEW_WINVER<br/>unset, win7 or win8?<br/>P3 D-07"}
    B -- no --> X1([exit 2])
    B -- yes --> C["run_checks"]
    C --> D{any check failed?}
    D -- yes --> X2([exit 1: run doctor])
    D -- no --> E{"prompt 1: Found Faugus<br/>Battle.net, continue? Y"}
    E -- no --> X3([exit 0: nothing changed])
    E -- yes --> F["acquire_lock"]
    F --> G{"recorded proton-tag names<br/>a complete build?"}
    G -- yes --> H["tag = recorded<br/>API only feeds a newer-tag notice<br/>P2 D-11, D-12"]
    G -- no --> I{"GitHub releases API<br/>resolved? PRT-02"}
    I -- no --> X4([exit 1])
    I -- yes --> J{"build already complete?<br/>P2 D-08"}
    J -- no --> K{"prompt 3: download<br/>tag (size)? Y"}
    K -- no --> X3
    K -- yes --> L["fetch, verify sha256,<br/>extract to staging, place<br/>P2 D-06, D-09"]
    J -- yes --> M
    L --> M["write proton-tag<br/>P2 D-10"]
    H --> N
    M --> N["launcher_status: one GET<br/>of latest.json"]
    N --> O{"runner already<br/>equals tag?"}
    O -- yes --> P["pass: no backup, no switch<br/>P2 D-14"]
    O -- no --> Q{"prompt 4: switch runner? Y"}
    Q -- no --> X5([exit 0: prefix steps not offered])
    Q -- yes --> R["want_switch"]
    P --> S
    R --> S{"WebView2 exe anywhere<br/>in the prefix? P3 D-08"}
    S -- no --> S1["prompt 5: install WebView2? Y"]
    S -- yes --> T
    S1 --> T{"all 3 registry items hold?<br/>P3 D-05"}
    T -- no --> T1["prompt 6: apply registry tweaks? Y"]
    T -- yes --> U
    T1 --> U{"launcher missing<br/>or outdated?"}
    U -- yes --> U1["prompt 7: install or update<br/>W3Champions? Y"]
    U -- no --> V
    U1 --> V{"a replaced build is<br/>removable? P3 D-15"}
    V -- yes --> V1["ask removal, default N"]
    V -- no --> W
    V1 --> W([unattended run])
```

## `install`: the unattended run

```mermaid
flowchart TD
    A([wants from the questions]) --> B{anything wanted?}
    B -- no --> F
    B -- yes --> C["download installers first,<br/>while Faugus may still run<br/>P3 D-02"]
    C --> D["wait_idle: prompt 2<br/>names what runs, waits for Enter,<br/>no retry cap, never kills<br/>P2 D-02, D-03, D-04"]
    D --> D1{removal wanted?}
    D1 -- yes --> D2["remove_prev: idle re-check,<br/>delete the replaced build"]
    D1 -- no --> E
    D2 --> E{switch wanted?}
    E -- yes --> E1{"idle_check again"}
    E1 -- busy --> X1([exit 1: rerun install])
    E1 -- idle --> E2["switch_runner: backup,<br/>atomic games.json write<br/>P2 D-20"]
    E -- no --> G
    E2 --> G["step_webview2 if wanted<br/>step_registry if wanted<br/>step_launcher if wanted<br/>each runs only through umu-run on the W3C build"]
    G --> H{"a step failed?<br/>P3 D-04"}
    H -- yes --> X2(["exit 1: finished steps are<br/>skipped on the rerun"])
    H -- no --> F["install_summary"]
    F --> I{anything still missing?}
    I -- yes --> X3([list it, exit 0])
    I -- no --> J["prompt 8: NAT block<br/>see the NAT chart<br/>P5 D-01"]
    J --> K["prompt 9: firewall ports and<br/>NTP hint, unprivileged reads only<br/>P5 D-08"]
    K --> KS{"installer's entry next to the install prefix?<br/>P11 D-01 (was P7 D-09)"}
    KS -- yes --> KY["no user entry; remove a clone-written one<br/>(P7 D-10); the installer's entry is never<br/>touched (P11 D-01)"]
    KS -- no --> K1["desktop entry and shipped icon copied: written without<br/>a prompt, atomically, only when complete<br/>P6 D-16"]
    KY --> L{"prompt 10: launch now? Y<br/>EOF counts as No"}
    K1 --> L
    L -- no --> X4([exit 0])
    L -- yes --> M([cmd_launch, same run lock])
```

## NAT offer

Shared by install prompt 8 and the launch LAN hint. It never checks the rule itself and sudo runs only here, with exactly
the printed text: in the foreground on a terminal, through `sudo -A` and the askpass dialog without one (P6 D-02).

```mermaid
flowchart TD
    A([nat_step]) --> B{"marker holds this boot_id?<br/>P5 D-04"}
    B -- yes --> B1([say applied this boot, done])
    B -- no --> C{"nft on PATH? else iptables?<br/>P5 D-05"}
    C -- nft --> D
    C -- iptables --> D
    C -- neither --> D
    D["print the block: apply command,<br/>removal lines, side-effect note,<br/>persistence notes printed only<br/>P5 D-06, D-07"]
    D --> E{variant is none?}
    E -- yes --> E1([say what to install, done])
    E -- no --> F{sudo on PATH?}
    F -- no --> F1["wait for Enter<br/>q and EOF also continue<br/>P5 D-02"]
    F -- yes --> G{"apply now with sudo?<br/>default N, EOF is No"}
    G -- no --> F1
    G -- yes --> G1{"stdin is a terminal?<br/>P6 D-06"}
    G1 -- yes --> H["sudo sh -c on the printed text"]
    G1 -- no --> G2["sudo -A sh -c on the printed text,<br/>SUDO_ASKPASS = w3c-askpass.sh: a zenity<br/>password dialog naming the command<br/>P6 D-02"]
    G2 --> I
    H --> I{sudo exit 0?}
    I -- no --> I1([say not applied, done])
    I -- yes --> J["write boot_id to the marker"]
    J --> K([done, never fails install])
    F1 --> K
```

## `launch`: preflight

```mermaid
flowchart TD
    A([launch]) --> A1{"stdin is not a terminal?<br/>P6 D-06"}
    A1 -- yes --> A2["append every line to launch.log<br/>P6 D-08"]
    A2 --> A3{"zenity usable?<br/>P6 D-07"}
    A3 -- no --> X0(["critical notification naming the fix,<br/>exit 1"])
    A3 -- yes --> B
    A1 -- no --> B{"W3C_LAUNCH_BAT unset, 0 or 1?<br/>P4 D-13"}
    B -- no --> X1([exit 2])
    B -- yes --> C["run_checks"]
    C --> D{"checks failed, launcher exe<br/>missing, or no setsid?"}
    D -- yes --> X2(["exit 1; an error dialog<br/>without a terminal, as every stop<br/>before the launcher starts<br/>P6 D-10"])
    D -- no --> E["log path = today's UTC file<br/>P5 D-12"]
    E --> F["acquire_lock<br/>P4 D-03"]
    F --> G{"W3Champions.exe already<br/>running? P4 D-05"}
    G -- yes --> X3([say so, exit 0])
    G -- pgrep failed --> X4([exit 1])
    G -- no --> G9["no terminal: earlier sessions move<br/>to launch.log.1, this run's lines<br/>stay in launch.log<br/>P6 D-09"]
    G9 --> H["warn only: no display,<br/>runner not a W3C build,<br/>newer launcher available"]
    H --> I{"Battle.net container<br/>on the bus?"}
    I -- yes --> M
    I -- no --> J["start_battlenet: faugus-launcher<br/>--game battlenet, wait up to 120 s<br/>a Faugus window never blocks<br/>P4 D-07<br/>umu backend: umu-run Battle.net Launcher.exe (P10 D-16)"]
    J --> K{container appeared?}
    K -- yes --> M
    K -- faugus missing --> X5([exit 1])
    K -- no --> L{"start in a separate container<br/>anyway? default N, never silent<br/>P4 D-08"}
    L -- no --> X6([exit 1])
    L -- yes --> L1["mode = run"]
    L1 --> M{"sign-in prompt, every launch<br/>Enter continues, q or EOF aborts<br/>P4 D-06"}
    M -- abort --> X7([exit 1])
    M -- Enter --> N{"Warcraft III user data<br/>folder exists? P4 D-09"}
    N -- no --> N1["ask to start WC3 once,<br/>then Enter to re-check"]
    N1 --> N
    N -- yes --> O["write W3Champions.bat if<br/>missing or different<br/>P4 D-14"]
    O --> P{"mDNSResponder.exe in prefix?<br/>P4 D-11"}
    P -- no --> P1["first-run Bonjour notice"]
    P -- yes --> Q
    P1 --> Q["Play guidance, one line<br/>P4 D-12"]
    Q --> R([run and follow])
```

## `launch`: run and follow

```mermaid
flowchart TD
    A([run and follow]) --> B["record the LAN-fail line count<br/>so only new lines count"]
    B --> C["spawn_launcher: setsid, detached,<br/>locks closed, output to wine.log<br/>stale Bonjour and Edge updaters killed first"]
    C --> D["mon_start: fork the match monitor,<br/>flock fd 8, one per session"]
    D --> E["follow_launcher: one tick per second"]
    E --> F{"W3Champions.exe seen?"}
    F -- first sighting --> F1["release the run lock<br/>so doctor works during play<br/>P4 D-03"]
    F1 --> G
    F -- never, 30 s passed --> X1([exit 1: did not start, an error<br/>dialog without a terminal P6 D-10])
    F -- gone after seen --> H
    F -- pgrep failed --> X2([exit 2: stopped waiting])
    F -- still running --> G["lan_hint_scan"]
    G --> G1{"new searchLanGame timed out<br/>line, first time this session?<br/>P4 D-15"}
    G1 -- yes --> G2["LAN test failed hint,<br/>then the NAT offer pauses the tick<br/>P5 D-03"]
    G1 -- no --> I
    G2 --> I{"on a terminal only: empty line<br/>on stdin within 1 s? P6 D-04"}
    I -- yes --> I1["restart requested<br/>P4 D-10"]
    I1 --> E
    I -- no or EOF --> E
    H{restart was requested?}
    H -- yes --> H1["wait for the old process,<br/>spawn again in the same container,<br/>never a kill"]
    H1 --> E
    H -- no --> J["wait for exit status<br/>n/a in .bat mode"]
    J --> J1{"no terminal, and a quick exit<br/>or a non-zero status?"}
    J1 -- yes --> J2["notification pointing at launch.log<br/>P6 D-04, D-13"]
    J1 -- no --> K
    J2 --> K([exit 0; EXIT trap stops the monitor])
```

## `update`

```mermaid
flowchart TD
    A([update]) --> B["run_checks, acquire_lock"]
    B --> C{"recorded build complete?"}
    C -- no --> C1["say: run install"]
    C -- yes --> D{"GitHub API resolved?"}
    D -- no --> D1["warn, continue"]
    D -- same tag --> D2["say up to date"]
    D -- newer tag --> D3["offer_proton<br/>compared with proton-tag only<br/>P3 D-14"]
    C1 & D1 & D2 & D3 --> E["launcher_status, sync record"]
    E --> F["watch_upstream: Wine protocol.def,<br/>issue #57, GE latest; advisory only<br/>P3 D-17"]
    F --> G{"offer_proton?"}
    G -- yes --> G1["ask: install and/or switch<br/>to the new tag? Y"]
    G -- no --> H
    G1 --> H{"launcher update needed?"}
    H -- "yes, and switching or already on W3C" --> H1["ask: update W3Champions? Y"]
    H -- "yes, but not on W3C" --> H2["say: run install"]
    H -- no --> I
    H1 & H2 --> I{"no switch offered and<br/>a replaced build is removable?<br/>P3 D-15"}
    I -- yes --> I1["ask removal, default N"]
    I -- no --> J
    I1 --> J{anything wanted?}
    J -- no --> X1([exit 0: nothing changed])
    J -- yes --> K["downloads first: Proton tarball<br/>if not complete, launcher MSI"]
    K --> L["wait_idle, once<br/>P3 D-13"]
    L --> L1{removal wanted?}
    L1 -- yes --> L2["remove_prev"]
    L1 -- no --> M
    L2 --> M{switch wanted?}
    M -- no --> P
    M -- yes --> N{"runner already on<br/>the new tag?"}
    N -- no --> N1{"idle_check"}
    N1 -- busy --> X2([exit 1: rerun update])
    N1 -- idle --> N2["switch_runner"]
    N -- yes --> O
    N2 --> O["write proton-tag.prev = old,<br/>proton-tag = new; old build stays<br/>P3 D-14, D-15"]
    O --> P{"MSI wanted?"}
    P -- yes --> P1["step_launcher on the new runner"]
    P -- no --> Q
    P1 --> Q([Update finished])
```

## `revert`

```mermaid
flowchart TD
    A([revert]) --> A1{"umu backend?"}
    A1 -- yes --> X0(["exit 0: nothing to revert<br/>P10 D-14"])
    A1 -- no --> B{"games.json and its<br/>Battle.net entry readable?"}
    B -- no --> X1([exit 1: run doctor])
    B -- yes --> C{"runner is a W3C build?<br/>recorded tag or *-W3C"}
    C -- no --> X2([exit 1: nothing to revert])
    C -- yes --> D{"proton-tag.prev names a complete<br/>build other than the runner?<br/>P3 D-16"}
    D -- yes --> E["acquire_lock, wait_idle"]
    E --> E1{"switch back to the<br/>previous W3C build? Y"}
    E1 -- no --> X3([exit 0: nothing changed,<br/>no fall-through])
    E1 -- yes --> E2["revert_write prev"]
    E2 --> E3["proton-tag = prev,<br/>delete proton-tag.prev"]
    E3 --> R["offer_remove the build left behind<br/>the menu entry stays: launch still works<br/>P6 D-17"]
    D -- no --> F{"newest backup whose runner<br/>is not a W3C build? P2 D-15"}
    F -- none --> X4([exit 1])
    F -- found --> G["acquire_lock, wait_idle"]
    G --> G1{"runner already<br/>equals the backup?"}
    G1 -- yes --> D1
    G1 -- no --> G2{"switch back to it? Y<br/>the launcher fails VerifyJob on it"}
    G2 -- no --> X3
    G2 -- yes --> G3["revert_write picked"]
    G3 --> D1["desktop_entry_remove: when desk_ours (Exec names<br/>a w3c-linux.sh, not a symlink), delete the per-user<br/>entry and its icon; else keep both with one<br/>Kept line; never /usr;<br/>the installer's own entry is skipped (P11 D-01)<br/>(P6 D-17, P9 D-01 to D-03)"]
    D1 --> R
    R --> R1{"dir exists and no games.json<br/>entry still uses it?"}
    R1 -- no --> X5([done])
    R1 -- yes --> R2{"remove it, about 1.5 GB?<br/>default N<br/>P2 D-17"}
    R2 -- no --> X6([kept; install or update<br/>switches back without a download])
    R2 -- yes --> R3["idle_check, delete the dir,<br/>clear records naming it"]
    R3 --> X5

    subgraph rw["revert_write"]
        W1{"idle_check"} -- busy --> W2([exit 1])
        W1 -- idle --> W3["set-runner: backup, atomic write"]
        W3 -- "file changed meanwhile (cas)" --> W2
    end
```

## `monitor`

A tail of the launcher's daily log, forked by `launch` or run standalone. Silent on stdout; outputs are `matches.log`
and `notify-send` (P5 D-14). Log lines are untrusted and are only matched against fixed substrings.

```mermaid
stateDiagram-v2
    [*] --> Idle: flock fd 8 taken,<br/>tail -F today's UTC log
    Idle --> Armed: PlayerMatchTelemetryReport emitted<br/>log game-end (P5 D-09)
    Armed --> Armed: another game-end<br/>re-arm
    Armed --> Idle: submitGameExited, no current match,<br/>within 120 s<br/>log RESULT-LOST, notify-send critical<br/>naming the newest replay (P5 D-11)
    Armed --> Idle: Match result ... sent successfully<br/>disarm, no line
    Armed --> Idle: submitGameExited after 120 s<br/>standby exit, no alarm (P5 D-15)
    Idle --> Idle: LanGameJoined<br/>log joined, unless w3c-test- (P5 D-10)
    Idle --> Idle: join bug line<br/>log JOIN-BUG (unverified form)
    Armed --> Armed: joined or join bug<br/>same tally lines
    Idle --> Idle: every 60 s, new UTC day file exists<br/>re-tail the new file (P5 D-12)
    Idle --> [*]: TERM, INT, or tail ended
    Armed --> [*]: TERM, INT, or tail ended
```

## `doctor` and `report`

Both are read-only. `doctor` runs the shared `run_checks` rows, then the W3C build rows (P2 D-13) and the prefix rows
(P3 D-12), then one `desktop entry` row (pass, absent, or pointing at a missing script; P6 D-17); the row can also read `(system)` for the packaged entry, `(user install)` for the one `make install-user` wrote (P11 D-01), or warn that a user file hides the system entry (P7 D-11). The `version` row comes first (P7 D-07), then `install location` (P11 D-07) and, with two installs, `other install` (P11 D-08). Only the shared rows can fail, so its exit status means "install can run". It makes one GET of `latest.json`
and nothing else (P3 D-10). `report` makes no network call and prints Markdown for a bug report. Neither warrants a chart.
