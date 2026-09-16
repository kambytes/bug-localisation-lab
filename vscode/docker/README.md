# VS Code bisect in Docker

Base image + version-specific image, following RippleGUItester's shape, for
reproducing VS Code GUI bugs at an arbitrary commit during `git bisect`.

## The idea

| | |
|---|---|
| `DockerfileBase` | Environment **and** the VS Code clone with dependencies installed at `BASE_COMMIT`. Built **once per bug**. ~40 min, ~8 GB. |
| `DockerfileVersion` | `FROM vscode:base`, one `COMMIT` build arg. Checkout → dependency delta → compile. Built **per bisect step**. ~5 min, ~2 GB of new layers. |

**Why the dependency install sits in the base.** Ripple's `DockerfileDiff` clones
and installs from scratch because it builds exactly two commits per pull
request — there is nothing to amortise. A bisect builds ten or more commits from
a narrow range where the lockfile barely moves, so the install belongs in the
layer built once. `DockerfileVersion` then runs `npm install` against an
already-populated `node_modules` and usually reports "up to date" in seconds.

It also keeps the disk manageable: because Docker layers are shared, each
version image adds only its own compile output rather than another 8 GB.

## Files

| File | |
|---|---|
| `DockerfileBase` | The base image. |
| `DockerfileVersion` | The per-commit image. |
| `entrypoint.sh` | Container PID 1: Xvfb + fluxbox + x11vnc + noVNC, then hold. |
| `launch.sh` | Launches the editor inside the container. |
| `bisect-step.sh` | Host wrapper: build, run, prune the previous image. |

## Prerequisites

**Docker Desktop → Settings → Resources → Memory ≥ 10 GB.**

`npm run compile` compiles all of `src/` in one Node process and is given an
8 GB heap. Below that it dies with `FATAL ERROR: Reached heap limit` (exit 134)
or is OOM-killed (exit 137). That is an environment failure, not a property of
the commit — `git bisect skip` it, never `bad`.

**Disk:** budget ~12 GB while a bisect is in progress (base + one version
image). `bisect-step.sh` prunes as it goes; `bisect-step.sh --status` shows
where you are.

**Apple silicon:** everything builds natively as `linux/arm64`. Do not add
`--platform=linux/amd64` — it emulates and is several times slower.

## 1. Build the base — once per bug

`BASE_COMMIT` should be the **good endpoint** of your bisect range: it is the
closest thing to the whole range, so the dependency delta at each step stays
small.

```bash
cd ~/Documents/Github/bug-localisation-lab

docker build -f vscode/docker/DockerfileBase \
  --build-arg BASE_COMMIT=<GOOD_SHA> \
  -t vscode:base vscode/docker
```

## 2. Two terminals, kept separate

The bisect and the builds do not talk to each other. You are the link: git
names a commit, you paste it into the other terminal.

### Terminal A — git bisect, in your clone

```bash
cd ~/Documents/Github/bug-localisation-lab/vscode/source/vscode
git bisect start
git bisect bad  <BAD_SHA>
git bisect good <GOOD_SHA>
```

git checks out a commit and prints it:

```
Bisecting: 812 revisions left to test after this (roughly 10 steps)
[ac4cbdf48759c7d8c3eb91ffe6bb04316e263c57] Fix something
```

Copy that SHA. Leave this terminal alone until you have a verdict.

### Terminal B — Docker, anywhere

```bash
~/Documents/Github/bug-localisation-lab/vscode/docker/bisect-step.sh <SHA>
docker exec -it vsc launch.sh
```

Open <http://localhost:6080/vnc.html> (password `vscode`) and try to reproduce
the bug. Quitting the editor leaves the desktop up, so you can relaunch as often
as you like.

`bisect-step.sh` takes the SHA as its only argument and resolves everything else
from its own location, so it does not care what directory you run it from or
what Terminal A is doing.

If you prefer the raw command instead of the wrapper, it is:

```bash
docker build -f vscode/docker/DockerfileVersion \
  --build-arg COMMIT=<SHA> -t vscode:<short-sha> vscode/docker
docker run -d --name vsc -p 5901:5901 -p 6080:6080 --shm-size=1g vscode:<short-sha>
```

— but then removing the previous image is on you, which at under 50 GB free is
the thing that ends a bisect early.

### Back in Terminal A — record the verdict

```bash
git bisect good      # bug absent
git bisect bad       # bug present
git bisect skip      # would not build, or you cannot tell
```

git prints the next commit. Copy it to Terminal B and repeat until it names the
first bad commit, then:

```bash
git bisect log > bisect.log
git bisect reset
```

## Housekeeping

```bash
vscode/docker/bisect-step.sh --status   # container, images, disk
vscode/docker/bisect-step.sh --clean    # remove all version images, keep the base
docker rmi vscode:base                  # done with this bug entirely
```

## Troubleshooting

**Compile exits 134 or 137** — Docker memory below 10 GB. Raise it. If it still
fails, lower the heap: edit `NODE_OPTIONS=--max-old-space-size=6144` in
`DockerfileBase` and rebuild the base.

**`ERROR: vscode:base does not exist`** — build the base first (step 1).

**Nothing on port 6080** —

```bash
docker logs vsc
docker exec vsc pgrep -a Xvfb x11vnc websockify
docker exec vsc cat /tmp/x11vnc.log /tmp/novnc.log
```

**The editor window never appears** — check the launch output; if the renderer
crashed, confirm the container was started with `--shm-size=1g` (the wrapper
does this).

**A commit genuinely will not build** — `git bisect skip`. A build failure is
not evidence about the bug.

**The lockfile moved mid-range** — expected; the version image detects it and
falls back to a full `npm ci` for that step. It will be slower, once.
