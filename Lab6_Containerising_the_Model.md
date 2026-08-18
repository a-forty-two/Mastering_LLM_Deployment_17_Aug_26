# Day 2 — Lab 6
## Containerising the model with TensorFlow Serving

**Time:** ~90 minutes
**Where:** your EC2 workstation, via Session Manager
**You will finish with:** a Docker image that serves your Day 1 model, running locally, and a
clear understanding of why it is not yet useful to anyone.

---

## 1. Why containers, and why this container

Day 1 ended with a directory: a SavedModel, a tokenizer, a preprocessing script and a
manifest. That directory runs on exactly one machine — the Colab runtime that produced it,
with its specific Python version, its specific TensorFlow build, and its specific set of
system libraries.

A container image is that entire environment frozen into a single artifact that runs
identically anywhere Docker runs. That is the whole idea. Everything else — layers, caching,
registries — is machinery in service of it.

**Why TensorFlow Serving specifically**, rather than wrapping the model in Python?

A naive Flask app that calls `model.predict()` loads TensorFlow into a Python process and
serves requests through the Python interpreter. TF Serving is a C++ binary purpose-built for
this: it loads SavedModels directly, handles model versioning and hot-swapping, exposes both
REST and gRPC, and never touches the Python interpreter on the request path. For a model
that is already a SavedModel, it is faster and considerably more robust.

The cost is that TF Serving speaks **tensors, not text**. That gap is the entire subject of
Lab 7, and you are going to feel it acutely at the end of this lab.

### The layer model, in one paragraph

A Docker image is a stack of read-only layers, one per instruction in the Dockerfile. When
you rebuild, Docker reuses cached layers up to the first instruction whose inputs changed,
then rebuilds everything after it. This has a direct consequence you will exploit later:
**put the things that change rarely near the top, and the things that change often near the
bottom.** A Dockerfile that copies your model before installing dependencies will re-install
dependencies every time the model changes.

---

## 2. Set up

Connect to your workstation through Session Manager, then:

```bash
source ~/day2-config.sh
day2_check
```

`day2-config.sh` was written to your home directory when the workstation was built, so it
should already be there and already filled in. Two things can go wrong:

- **`No such file or directory`** — ask your instructor for the config block, then create the
  file yourself using the heredoc pattern in §3 below.
- **`day2_check` reports MISSING values** — open the file, fill in what is blank from your
  credential slip and the values your instructor gave you, then save and re-source it:

  ```bash
  nano ~/day2-config.sh      # edit, then Ctrl-O, Enter to save, Ctrl-X to exit
  source ~/day2-config.sh
  day2_check
  ```

Nothing below works until `day2_check` prints `OK`. **Re-run `source ~/day2-config.sh` after
every reconnect** — a new Session Manager shell inherits nothing from the old one.

Confirm the Day 1 artifact arrived:

```bash
cd /workspace
ls -R day2-deploy/ | head -40
du -sh day2-deploy/*
```

You should see `saved_model/1/` containing `saved_model.pb` and a `variables/` directory,
plus `tokenizer/`, `hf_model/`, `preprocess.py` and `deployment_manifest.json`.

Read the manifest — it is the contract between Day 1 and Day 2:

```bash
cat day2-deploy/deployment_manifest.json | python3 -m json.tool
```

Note three things: the **serving contract** (what the signature expects and returns), the
**measured metrics** from Day 1 (the baseline you compare your served model against), and the
**day2_checklist**.

---

## 3. Your first Dockerfile — deliberately naive

### How every file in these labs gets created

Session Manager gives you no drag-and-drop, no file upload and no graphical editor, so every
file today is created **by pasting a block into the terminal**. The pattern is always the
same:

```
cat > filename <<'EOF'
...contents...
EOF
```

Read it as: *"write everything I type, until a line that says `EOF`, into `filename`."*

- **Paste the whole block at once**, from the `cat >` line down to and including the final
  `EOF`, then press Enter. Not line by line.
- **If your prompt becomes a bare `>` and stays there**, the closing `EOF` never arrived.
  Type `EOF` and press Enter to finish, or `Ctrl-C` to abandon and start over.
- **`cat >` overwrites; `cat >>` appends.** Re-pasting a block replaces the file, which is
  exactly what you want when you got it wrong.
- **`<<'EOF'` in quotes is literal** — `$VAR` is written to the file as the text `$VAR`.
  Without quotes (`<<EOF`) the shell substitutes the value first. Both forms appear today;
  copy them exactly as printed.
- **Always read the file back** with `cat filename` afterwards. Ten seconds now saves a
  confusing build failure later.
- `nano filename` is installed if you would rather use an editor: type or paste, `Ctrl-O`
  and `Enter` to save, `Ctrl-X` to exit.

### Create `/workspace/serving/Dockerfile.v1`

`mkdir -p` creates the directory (and does not complain if it already exists), `cd` moves
into it, and `cp -r` copies the Day 1 artifact in as `context/` — Docker can only see files
underneath the directory you build from, which is why we copy rather than point at the
original:

```bash
mkdir -p /workspace/serving && cd /workspace/serving
cp -r /workspace/day2-deploy ./context

cat > Dockerfile.v1 <<'EOF'
# Dockerfile.v1 — the obvious version. We will measure it, then fix it.
FROM tensorflow/serving:latest

ENV MODEL_NAME=sentiment

COPY context /models/sentiment
EOF
```

Confirm the file exists and holds what you think it holds before building anything:

```bash
ls
cat Dockerfile.v1
```

You should see `Dockerfile.v1` and `context` listed, and `cat` should print back exactly what
you pasted. Build it and look at the result:

```bash
docker build -f Dockerfile.v1 -t sentiment-serving:v1 .
docker images sentiment-serving
```

**This build is wrong in two ways**, and both are worth finding by inspection rather than
being told.

Run the container and watch it fail. **Note the `-it`** — it matters, and the reason is
directly below:

```bash
docker run --rm -it -p 8501:8501 sentiment-serving:v1
```

TF Serving expects `/models/<name>/<version>/`, where version is an integer directory. We
copied the whole artifact folder, so it sees `saved_model/`, `tokenizer/`, `hf_model/` — no
numeric version directory at all. Read the error, then press `Ctrl-C`.

**Why `-it`, and what happens without it.** TF Serving does not exit on this error — it
retries once per second, forever. Without `-it`, `docker run` does not forward your `Ctrl-C`
to the container: your shell prompt comes back, but **the container is still running and
still holding port 8501**. Section 5 then fails with `Bind for 0.0.0.0:8501 failed: port is
already allocated`, and because that failed `docker run` still creates the container, the
obvious retry fails a second time with `The container name "/serving" is already in use`.

Confirm you are actually back to a clean slate before moving on:

```bash
docker ps          # should list no containers
```

If anything is still up, clear out the containers from this image:

```bash
docker ps -aq --filter ancestor=sentiment-serving:v1 | xargs -r docker rm -f
```

**Exercise 6.1.** Before reading on, work out what the layout under `/models/sentiment/`
needs to be. Use `docker run --rm -it --entrypoint bash sentiment-serving:v1` and look
around with `ls`.

---

## 4. Fix the layout, then measure the waste

Create `Dockerfile.v2`:

```bash
cat > Dockerfile.v2 <<'EOF'
# Dockerfile.v2 — correct layout.
FROM tensorflow/serving:latest

ENV MODEL_NAME=sentiment

# TF Serving wants /models/<name>/<version>/. Our SavedModel already lives in
# a directory called "1", so copying saved_model/ gives us exactly that.
COPY context/saved_model /models/sentiment
EOF
```

Read it back — one changed line is the whole difference between a broken image and a working
one, so check rather than assume:

```bash
cat Dockerfile.v2
```

The `COPY` line must end in `context/saved_model /models/sentiment`. Then build:

```bash
docker build -f Dockerfile.v2 -t sentiment-serving:v2 .
docker images sentiment-serving
```

Compare the two sizes. Then look at where the space went:

```bash
docker history sentiment-serving:v1 --human --format "table {{.Size}}\t{{.CreatedBy}}" | head -5
docker history sentiment-serving:v2 --human --format "table {{.Size}}\t{{.CreatedBy}}" | head -5
```

`v1` carries `hf_model/` and `tokenizer/` — the full Hugging Face checkpoint — which TF
Serving cannot use and will never read. That is dead weight in every pull, on every task
start, for the life of the deployment.

### Why this matters more than it looks

On your laptop, a few hundred extra megabytes is nothing. On ECS Fargate, **every task start
pulls the image**. Autoscaling out by ten tasks pulls it ten times. A cold start after a
deployment pulls it on every task simultaneously. Image size converts directly into
scale-out latency, and scale-out latency is what your p99 looks like during a traffic spike.

### Add a .dockerignore

The build *context* — everything Docker sends to the daemon before building — is a separate
waste. You are about to create a file named `.dockerignore`: Docker's list of things to leave
out of that context.

**Write down your `v1` and `v2` sizes before you create it.** `.dockerignore` applies to
every build in this directory, including `Dockerfile.v1` — so once it exists, a rebuilt
`v1` no longer contains `hf_model/` either, the two images converge, and the difference
you just measured disappears. That is not a bug; it is the fix working. But it means the
comparison is only available *once*, so record it first.

#### Step 1 — be in the right directory

Docker only reads a `.dockerignore` from the **root of the build context** — the directory
you pass to `docker build` as the trailing `.`. Here that is `/workspace/serving`, alongside
the two Dockerfiles:

```bash
cd /workspace/serving
pwd
```

`pwd` ("print working directory") must print `/workspace/serving`. If it prints anything
else, run the `cd` again before continuing — a `.dockerignore` in the wrong directory is
silently ignored, with no error to tell you.

#### Step 2 — create the file

Same heredoc pattern as the Dockerfiles above: paste the **entire** block, from `cat >` down
to and including the final `EOF`, then press Enter. Read it as *"write everything I type
until a line saying `EOF` into a file named `.dockerignore`"*:

```bash
cat > .dockerignore <<'EOF'
context/hf_model
context/tokenizer
context/preprocess.py
**/__pycache__
**/.ipynb_checkpoints
EOF
```

If your prompt turns into a bare `>` and stays there, you did not paste the closing `EOF`.
Type `EOF` and press Enter to close the file.

#### Step 3 — confirm it exists and reads correctly

A filename beginning with a dot is **hidden** — plain `ls` will not list it. Use `ls -a`:

```bash
ls -a
cat .dockerignore
```

You should see `.dockerignore` in the listing, and `cat` should print exactly those five
lines. If `cat` reports *"No such file or directory"*, you were in the wrong directory at
step 1: `cd /workspace/serving` and repeat step 2.

**What the five lines do.** The first three name Day 1 artifacts TF Serving will never read —
`hf_model/` is the full Hugging Face checkpoint, and `tokenizer/` and `preprocess.py` belong
to the API you build in Lab 7. The last two use `**` to mean "at any depth", dropping Python
and Jupyter scratch directories wherever they appear.

#### Step 4 — rebuild and read the context size

Now rebuild — and note the `prune`, which is not optional if you want to *see* anything:

```bash
docker builder prune -af
docker build -f Dockerfile.v2 -t sentiment-serving:v2 .
```

Watch the "transferring context" line at the top of the build output.

**Why the prune is there.** BuildKit transfers the build context incrementally: after the
first build it already has your context cached, so every later build reports a few hundred
bytes regardless of what `.dockerignore` says. Without the prune you would see
`375MB → 824B → 824B` across the three builds, and would wrongly credit that drop to
`.dockerignore` — it is just the cache. Pruning forces a cold transfer so the number you
read is the real one.

**Exercise 6.2.** Record four numbers in your notes: the `v1` image size, the `v2` image
size, and the cold build context size before and after `.dockerignore`. The "before" figure
is the one from your very first `v1` build, when the builder cache was empty; the "after" is
the one you just measured following the prune. The gap between them is what the
`.dockerignore` bought you.

Cold context sizes should land around **376 MB → 189 MB** — the `hf_model/` and `tokenizer/`
directories no longer being shipped to the daemon at all.

For the images, a correct run looks roughly like this — your numbers will differ, but the
*shape* should not:

| | Image size | Carries |
|---|---|---|
| `v1` | ~1.19 GB | SavedModel + `hf_model/` + `tokenizer/` |
| `v2` | ~1.00 GB | SavedModel only |

That ~190 MB gap is the full Hugging Face checkpoint that TF Serving will never read,
travelling on every single task start for the life of the deployment.

---

## 5. Run it and interrogate the contract

```bash
docker run -d --name serving -p 8501:8501 sentiment-serving:v2
docker logs serving | tail -20
```

Look for a line reporting the model loaded successfully and HTTP serving on 8501.

**Is the model alive?**

```bash
curl -s http://localhost:8501/v1/models/sentiment | python3 -m json.tool
```

**What does it actually expect?** This is the question that matters, and TF Serving will
tell you directly — no need to install TensorFlow anywhere:

```bash
curl -s http://localhost:8501/v1/models/sentiment/metadata | python3 -m json.tool
```

Read the `signature_def` block carefully. You should see inputs named `input_ids`,
`attention_mask` and `token_type_ids`, each with shape `[-1, -1]` — the dynamic shape Lab 5
exported so you can serve any sequence length — and outputs for logits, probabilities and
predicted class.

Compare this against the `serving` block in `deployment_manifest.json`:

```bash
python3 -c "import json; print(json.dumps(json.load(open('/workspace/day2-deploy/deployment_manifest.json'))['serving'], indent=2))"
```

They must agree — same three input names, same dtype, same dynamic shapes, same three
outputs. If they do not, the artifact and the manifest have drifted and you should stop and
say so.

---

## 6. The first prediction — and the problem

Send a request. Note what you are sending:

```bash
cat > /tmp/req.json <<'EOF'
{
  "signature_name": "serving_default",
  "inputs": {
    "input_ids":      [[101, 1045, 3866, 2023, 3185, 102, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
    "attention_mask": [[1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
    "token_type_ids": [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]
  }
}
EOF

curl -s -X POST http://localhost:8501/v1/models/sentiment:predict \
  -d @/tmp/req.json | python3 -m json.tool
```

You should get logits, probabilities and a predicted class back.

**Now stop and look at what you just did.** Those numbers are the token IDs for *"i loved
this movie"*. A human being cannot produce that array. Neither can a mobile app, a web
frontend, or another service. Your model is deployed and completely unusable.

This is not a flaw in TF Serving. It is the correct division of responsibility: the model
server does inference, and something else owns the text-to-tensor contract. That something
else is Lab 7.

**Exercise 6.3.** Try sending only `input_ids` without the other two tensors. Read the error.
This tells you something important about how strict the signature contract is, and it is a
failure you will see again in Lab 8 when a task definition is subtly wrong.

---

## 7. Batching — and a case-study callback

TF Serving can batch concurrent requests server-side before running inference. Enable it with
a config file:

```bash
cat > /workspace/serving/batching.config <<'EOF'
max_batch_size { value: 32 }
batch_timeout_micros { value: 5000 }
max_enqueued_batches { value: 100 }
num_batch_threads { value: 2 }
EOF
```

That heredoc wrote `/workspace/serving/batching.config`. Confirm it landed before using it:

```bash
cat /workspace/serving/batching.config
```

To actually switch batching on, the model server needs two extra flags — and you do **not**
need to rebuild the image for that. The `tensorflow/serving` entrypoint appends any arguments
you give `docker run` to the server command, and `-v` mounts a file from the workstation into
the container:

```bash
docker run -d --name serving-batch -p 8502:8501 \
  -v /workspace/serving/batching.config:/etc/batching.config \
  sentiment-serving:v2 \
  --enable_batching --batching_parameters_file=/etc/batching.config

docker logs serving-batch | tail -20
```

Note the port: `-p 8502:8501` publishes this one on host port **8502**, so your un-batched
server on 8501 keeps running and you can compare the two side by side. Check it answers:

```bash
curl -s http://localhost:8502/v1/models/sentiment | python3 -m json.tool
```

When you have finished measuring, remove it so it is not holding a port later:

```bash
docker stop serving-batch && docker rm serving-batch
```

Before you reach for it, recall the case study from Day 1. The published account of serving
BERT at over a billion requests a day on CPU reported that **batch size 1 outperformed
batching**, because padding to the longest sequence in the batch wasted more compute than
batching saved.

Your Lab 5 sequence-length table showed the same effect from the other direction: latency
scales with sequence length, so a batch containing one long input drags every short input in
that batch up to its cost.

**Exercise 6.4 (optional, and genuinely open).** Enable batching, then measure. Does it help
your model, on this hardware, with your traffic pattern? A defensible "we measured it and it
hurt" is a better outcome than adopting a default because it sounds sophisticated.

---

## 8. Pinning, and the reproducibility trade-off

`FROM tensorflow/serving:latest` is a problem. `latest` moves. An image that builds today may
not build next month, which defeats the point of containerising in the first place.

Find out what you actually ran — ask the binary itself:

```bash
docker run --rm tensorflow/serving:latest --version
```

That reports both the ModelServer and the TensorFlow library version. The ModelServer
version is the one that matches a Docker Hub tag.

(You may see `docker inspect <image> --format '{{.Config.Image}}'` suggested elsewhere for
this. It returns an empty string for anything BuildKit built, which is every image in these
labs, so it will not tell you what you want to know.)

Confirm the tag exists before you commit to it:

```bash
docker pull tensorflow/serving:2.20.0    # <- the version you measured
```

Now pin it — edit `Dockerfile.v2` so `FROM` names that version instead of `latest`.

**Step 1 — put your version in a variable.** Use the number that printed on *your* screen,
not the one written here:

```bash
export SERVING_TAG="2.20.0"      # <- replace with YOUR version
echo "$SERVING_TAG"
```

The `echo` must print your version back. A blank line means the `export` did not take — run
it again.

**Step 2 — edit the file in place.** `sed -i` rewrites a file without opening an editor;
`s|old|new|` means "substitute old with new". The quotes must be **double** here, so the
shell expands `${SERVING_TAG}` before sed sees it:

```bash
cd /workspace/serving
sed -i "s|tensorflow/serving:latest|tensorflow/serving:${SERVING_TAG}|" Dockerfile.v2
cat Dockerfile.v2
```

Read the output: the `FROM` line should now carry your version. If it still says `latest`,
`SERVING_TAG` was empty — go back to step 1.

Prefer to type it yourself? `nano Dockerfile.v2` opens a plain text editor: change the line,
then `Ctrl-O` and `Enter` to save, `Ctrl-X` to exit.

**Step 3 — rebuild on the pinned base, and record the tag for the rest of the day:**

```bash
docker build -f Dockerfile.v2 -t sentiment-serving:v2 .
echo "export SERVING_TAG=\"${SERVING_TAG}\"" >> ~/day2-config.sh
tail -3 ~/day2-config.sh
```

`>>` **appends** — it adds a line without destroying what is already in the file. (A single
`>` would overwrite your whole config, which is a bad afternoon.) Every future shell picks
the value up once you `source ~/day2-config.sh`.

**The trade-off worth naming out loud:** pinning gives reproducibility and costs you security
patches. A pinned base image is a base image that stops receiving fixes. The professional
answer is not "never pin" or "pin forever" — it is pin, and own a rebuild cadence.

---

## 9. Clean up

Stop and remove the container. Lab 7 starts its own copy of the model server through Docker
Compose, so leaving this one running just puts a second TF Serving process on the same two
vCPUs and distorts the timings you take there:

```bash
docker stop serving && docker rm serving
docker ps
```

`docker ps` should list nothing. Your **images** stay where they are — removing a container
does not remove the image it ran from — and Lab 7 needs `sentiment-serving:v2`:

```bash
docker images sentiment-serving
```

---

## What you built

- A container image serving your Day 1 model, with a correct model layout
- A measured understanding of image size and why it converts into scale-out latency
- The serving contract read from the running server, not assumed
- A concrete demonstration that a deployed model with no preprocessing layer is not a product

## Checklist before moving on

- [ ] `docker images sentiment-serving` shows both `v1` and `v2`, and you can explain the size difference
- [ ] `curl .../metadata` returns a signature matching the manifest
- [ ] A prediction returns sensible probabilities
- [ ] Your Dockerfile pins an explicit TF Serving version
- [ ] You have written down the numbers from Exercise 6.2

## Discussion

1. Your image contains the model weights. What are the consequences for a team that retrains
   weekly — and what would change if the model were loaded from S3 at container start
   instead?
2. TF Serving supports multiple versions of a model simultaneously and can shift traffic
   between them. What deployment strategies does that enable that a rebuild-and-redeploy
   cycle does not?
3. `.dockerignore` excluded the tokenizer from this image. Lab 7 needs it. Where should it
   live, and what does your answer imply about keeping the two in sync?
