# Mastering LLM Deployment

**Containerise a model, put an API in front of it, and run it on AWS.**

By the end of today the sentiment model you optimised on Day 1 will be answering HTTP
requests from the public internet, running on infrastructure you never provisioned, from a
container you built an hour earlier.

Everything runs in a browser. **You do not need** the AWS CLI, Docker, SSH keys, access
keys, or admin rights on your laptop.

---

## Contents

| | |
|---|---|
| [Before you start](#before-you-start) | What you need in front of you |
| [Get into your machine](#get-into-your-machine) | Sign in → shell, ~5 minutes |
| [Lab 6 — Containerise the model](#lab-6--containerise-the-model) | ~90 min |
| [Lab 7 — The API layer](#lab-7--the-api-layer) | ~90 min |
| [Lab 8 — Deploy to ECR and ECS](#lab-8--deploy-to-ecr-and-ecs) | ~90 min |
| [When something breaks](#when-something-breaks) | Real errors and their fixes |

The three `Lab*.md` files in this repo are the **full lab guides** — they explain *why*
each step exists and contain the exercises and discussion questions. This README is the
**step-by-step path**: what to type, what you should see, and how to know you are done.
Work from this; read those when you want the reasoning.

---

## Before you start

You need two things:

1. **A browser.** Chrome, Edge, Firefox or Safari are all fine.
2. **Your credential slip**, handed to you individually. It has your console URL, your
   username (`pax01`, `pax07`, …) and your password.

> Everything you create is named after your `PAX` ID so nothing collides. Using someone
> else's ID will collide with their work.

---

## Get into your machine

### 1. Sign in

Open the console URL from your slip:

```
https://<ACCOUNT_ID>.signin.aws.amazon.com/console
```

Enter your username and password. **Check the region reads "N. Virginia" (`us-east-1`)** in the
top-right corner — if it says anything else, change it. Half the confusing failures in a
training environment are resources in one region and commands run against another.

### 2. Open a shell on your workstation

1. Type **Systems Manager** in the search bar at the top, open it
2. In the left sidebar, click **Session Manager**
3. Click **Start session**
4. Select **`llm-deploy-day2-<your-pax-id>`** from the instance list
5. Click **Start session**

You should get a black terminal. Confirm it works:

```bash
docker ps
```

You should see an empty table with column headers (`CONTAINER ID   IMAGE   ...`) — not a
permission error.

### 3. How to create a file in this terminal

Many steps today say *"create `<some file>`"*. Session Manager gives you no drag-and-drop, no
file upload and no graphical editor, so **every file today is created by pasting a block into
the terminal**. The pattern is always the same:

```
cat > filename <<'EOF'
...file contents...
EOF
```

Read it as: *"write everything I type, until a line that says `EOF`, into `filename`."*

**How to use it:** copy the whole block — from the `cat >` line down to and including the
final `EOF` — paste it into the terminal, and press Enter. One paste, not line by line.

Five things that catch people out:

| | |
|---|---|
| **The closing `EOF` is part of the block** | Miss it and your prompt becomes a bare `>` and sits there waiting. Type `EOF` and press Enter to finish the file, or `Ctrl-C` to abandon it and start over. |
| **`cat >` overwrites, `cat >>` appends** | Got it wrong? Just re-paste the whole block. There is nothing to delete first. |
| **`<<'EOF'` in quotes is literal** | Quoted, `$VAR` is written into the file as the text `$VAR`. Unquoted (`<<EOF`), the shell substitutes its value first. Both appear today — copy them exactly as printed. |
| **Pasting** | `Ctrl-V` works in the browser terminal (`Cmd-V` on a Mac), as does right-click → Paste. |
| **Hidden files** | Names starting with a dot — `.dockerignore` — do not show up under plain `ls`. Use `ls -a`. |

**Always read the file back after creating it.** Ten seconds here saves a confusing build
failure later:

```bash
cat filename
```

If you would rather use an editor, `nano filename` is installed: type or paste, then `Ctrl-O`
and `Enter` to save, `Ctrl-X` to exit. The heredoc blocks are given because they are
copy-paste-proof; nano is there for when you want to *change* a file you already have.

### 4. Load your configuration

`day2-config.sh` was written to your home directory when the workstation was built, already
filled in with your account, region and PAX ID. You do not normally have to create it.
Confirm it is there, then load it:

```bash
ls -l ~/day2-config.sh
source ~/day2-config.sh
day2_check
```

`source` runs the file **in your current shell**, so the variables it sets stay set for the
commands that follow. Running it any other way — `bash ~/day2-config.sh` or
`./day2-config.sh` — sets them inside a shell that immediately exits, and you get nothing.

> **If `ls` reports "No such file or directory"**, ask your instructor for the config block
> and create it yourself with the pattern from §3 — paste their contents in place of the
> middle line, then the closing `EOF`:
>
> ```bash
> cat > ~/day2-config.sh <<'EOF'
> <-- paste the contents your instructor gave you here, replacing this line -->
> EOF
> ```
>
> Then `head -20 ~/day2-config.sh` to check it landed, and run the two commands above.

Expected — with **your** PAX ID, not `pax01`:

```
  identity : pax01
  account  : 2887xxxxxxxx in us-east-1
  registry : 2887xxxxxxxx.dkr.ecr.us-east-1.amazonaws.com
  cluster  : llm-deploy-day2-cluster
OK
```

> **Do this at the start of every lab, and after every reconnect.** A new Session Manager
> shell does not inherit variables from an old one. Almost every *"command not found"* or
> *"repository does not exist"* error today traces back to a shell that never sourced this
> file.

### 5. Confirm the Day 1 model arrived

```bash
ls /workspace/day2-deploy/
du -sh /workspace/day2-deploy/*
```

You should see five entries: `saved_model/`, `tokenizer/`, `hf_model/`, `preprocess.py`,
`deployment_manifest.json`.

**If this directory is empty, stop and tell your instructor.** Do not work around it —
every lab today depends on it.

---

## Lab 6 — Containerise the model

**Full guide:** [`Lab6_Containerising_the_Model.md`](Lab6_Containerising_the_Model.md)
**You finish with:** a Docker image serving your model, and a clear sense of why it isn't
useful to anyone yet.

### 6.1 — Set up the build directory

```bash
source ~/day2-config.sh
mkdir -p /workspace/serving && cd /workspace/serving
cp -r /workspace/day2-deploy ./context
```

### 6.2 — Build the obvious version, and watch it fail

Create `Dockerfile.v1` — paste the whole block, closing `EOF` included:

```bash
cd /workspace/serving

cat > Dockerfile.v1 <<'EOF'
FROM tensorflow/serving:latest
ENV MODEL_NAME=sentiment
COPY context /models/sentiment
EOF
```

Read it back before building. `ls` should show `Dockerfile.v1` and `context`:

```bash
ls
cat Dockerfile.v1
```

```bash
docker build -f Dockerfile.v1 -t sentiment-serving:v1 .
docker run --rm -it -p 8501:8501 sentiment-serving:v1
```

**Expected — this is supposed to fail:**

```
No versions of servable sentiment found under base path /models/sentiment.
Did you forget to name your leaf directory as a number (eg. '/1/')?
```

The container keeps retrying rather than exiting. Read the error, then press `Ctrl-C`.

> **The `-it` is not optional.** Without it, `docker run` does not forward your `Ctrl-C` to
> the container: your prompt returns but the container keeps running and keeps port 8501,
> and section 6.5 then fails with `port is already allocated`. Confirm with `docker ps` that
> nothing is left running; if something is, clear it with
> `docker ps -aq --filter ancestor=sentiment-serving:v1 | xargs -r docker rm -f`.

TF Serving wants `/models/<name>/<version>/` where version is a *number*. You copied the
whole artifact folder, so it found `saved_model/`, `tokenizer/`, `hf_model/` — and no
numeric directory anywhere.

### 6.3 — Fix the layout

Create `Dockerfile.v2`. One line differs from `v1` — the `COPY` source:

```bash
cd /workspace/serving

cat > Dockerfile.v2 <<'EOF'
FROM tensorflow/serving:latest
ENV MODEL_NAME=sentiment
COPY context/saved_model /models/sentiment
EOF
```

Check that one line landed correctly — it is the whole difference between a broken image and
a working one:

```bash
cat Dockerfile.v2
```

`saved_model/` already contains a directory called `1`, so this lands the model at
`/models/sentiment/1/` — exactly what TF Serving wants.

```bash
docker build -f Dockerfile.v2 -t sentiment-serving:v2 .
docker images sentiment-serving
```

**Write both sizes down now.** Roughly:

| | Size | Carries |
|---|---|---|
| `v1` | ~1.19 GB | SavedModel + `hf_model/` + `tokenizer/` |
| `v2` | ~1.00 GB | SavedModel only |

That ~190 MB gap is the Hugging Face checkpoint TF Serving will never read — dead weight on
every task start, forever.

### 6.4 — Add a `.dockerignore`

`.dockerignore` is Docker's list of things to leave out of the build context — the pile of
files sent to the Docker daemon before a build even starts.

> **Record your v1/v2 sizes before you create it.** `.dockerignore` applies to
> `Dockerfile.v1` too, so a rebuilt `v1` no longer carries the extra files and the comparison
> disappears.

**Step 1 — be in the right directory.** Docker only reads a `.dockerignore` from the root of
the build context, which for us is `/workspace/serving`. One in the wrong place is ignored
silently, with no error:

```bash
cd /workspace/serving
pwd            # must print /workspace/serving
```

**Step 2 — create the file.** Paste the whole block including the final `EOF`:

```bash
cat > .dockerignore <<'EOF'
context/hf_model
context/tokenizer
context/preprocess.py
**/__pycache__
**/.ipynb_checkpoints
EOF
```

**Step 3 — confirm it exists.** The leading dot makes it hidden, so use `ls -a`, not `ls`:

```bash
ls -a
cat .dockerignore
```

You should see `.dockerignore` listed, and `cat` should print those five lines. If `cat` says
*"No such file or directory"*, you were in the wrong directory at step 1 — `cd` there and
repeat step 2.

**Step 4 — rebuild and watch the *"transferring context"* line shrink.** The `prune` is not
optional: BuildKit caches the context between builds, so without it every rebuild reports a
few hundred bytes no matter what `.dockerignore` says, and you would credit the cache for
this fix:

```bash
docker builder prune -af
docker build -f Dockerfile.v2 -t sentiment-serving:v2 .
```

Cold context should drop from roughly **376 MB to 189 MB**. The first three lines of the file
drop the Day 1 artifacts TF Serving never reads; the last two use `**` ("at any depth") to
drop Python and Jupyter scratch directories wherever they appear.

### 6.5 — Run it and read the contract

```bash
docker run -d --name serving -p 8501:8501 sentiment-serving:v2
sleep 15
curl -s http://localhost:8501/v1/models/sentiment | python3 -m json.tool
```

**Expected:**

```json
{ "model_version_status": [ { "version": "1", "state": "AVAILABLE",
    "status": { "error_code": "OK", "error_message": "" } } ] }
```

Now ask the server what it expects:

```bash
curl -s http://localhost:8501/v1/models/sentiment/metadata | python3 -m json.tool
```

You should find three inputs — `input_ids`, `attention_mask`, `token_type_ids`, all
`DT_INT32` with shape `[-1, -1]` — and three outputs: `logits`, `probabilities`,
`predicted_class`. Compare against `serving_contract` in `deployment_manifest.json`. They
must agree.

### 6.6 — The first prediction, and the problem

```bash
curl -s -X POST http://localhost:8501/v1/models/sentiment:predict \
  -d '{"signature_name":"serving_default","inputs":{
       "input_ids":[[101,1045,3866,2023,3185,102,0,0,0,0,0,0,0,0,0,0]],
       "attention_mask":[[1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0]],
       "token_type_ids":[[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]]}}' \
  | python3 -m json.tool
```

**Expected:** `predicted_class: 1`, probabilities around `[0.008, 0.992]`.

Those numbers are the token IDs for *"i loved this movie"*. **A human cannot produce that
array. Neither can a mobile app or a web frontend.** Your model is deployed and completely
unusable — which is the entire point of Lab 7.

### ✅ Checkpoint

- [ ] `docker images sentiment-serving` shows `v1` and `v2`, and you can explain the size gap
- [ ] `/metadata` returns a signature matching the manifest
- [ ] A prediction returns sensible probabilities
- [ ] You wrote down the v1/v2 sizes

**Leave the `serving` container running** if you are going straight into Lab 7.

---

## Lab 7 — The API layer

**Full guide:** [`Lab7_The_API_Layer.md`](Lab7_The_API_Layer.md)
**You finish with:** two containers running together, accepting raw text over HTTP.

### 7.1 — Set up

`cp` copies a file, `cp -r` copies a directory, and the trailing `.` means "into the
directory I am in now":

```bash
source ~/day2-config.sh
mkdir -p /workspace/api && cd /workspace/api
cp /workspace/day2-deploy/preprocess.py .
cp -r /workspace/day2-deploy/tokenizer .
```

Confirm both landed — an empty `tokenizer/` shows up much later as a container that exits on
startup, which is a miserable way to find out:

```bash
ls -la
ls tokenizer/
```

You want `preprocess.py` plus a `tokenizer/` containing `tokenizer_config.json` and
`vocab.txt`. If it is empty, re-run the `cp -r`; if the source is empty too, tell your
instructor.

### 7.2 — Check the interface before you build anything

This is the step that saves you an hour. Confirm what `preprocess.py` actually exposes:

```bash
python3 - <<'PY'
import ast
tree = ast.parse(open("preprocess.py").read())
print("module-level functions:", [n.name for n in tree.body if isinstance(n, ast.FunctionDef)])
for n in tree.body:
    if isinstance(n, ast.ClassDef):
        for m in n.body:
            if isinstance(m, ast.FunctionDef):
                print(f"  {n.name}.{m.name}", [a.arg for a in m.args.args])
PY
```

**Expected:**

```
module-level functions: []
  Preprocessor.__init__ ['self', 'tokenizer_dir']
  Preprocessor.bucket_for ['self', 'texts']
  Preprocessor.encode ['self', 'texts']
  Preprocessor.decode ['probabilities']
```

It is a **class**, not module-level functions. The `app.py` in the full lab guide is
written against exactly this. Two traps if you adapt anything:

- `encode` takes **only** `texts` — the preprocessor already holds the tokenizer
- `decode` takes **only the probabilities array**, not the whole `outputs` dict. Passing the
  dict does not raise an error, it returns confident nonsense

### 7.3 — Create the application

`app.py` is ~120 lines, so it lives in the full guide rather than here. Open
[`Lab7_The_API_Layer.md`](Lab7_The_API_Layer.md) §3, copy the **entire** block — from
`cat > /workspace/api/app.py <<'EOF'` down to and including the last `EOF` — paste it into
the terminal in one go, and press Enter.

Then confirm the paste was not truncated. `ast.parse` reads the file as Python without
running it, so a cut-off paste shows up here rather than sixty seconds into a Docker build:

```bash
cd /workspace/api
wc -l app.py
python3 -c "import ast; ast.parse(open('app.py').read()); print('app.py parses cleanly')"
```

A `SyntaxError` means the paste was incomplete — re-paste the whole block, which overwrites
the broken file.

The three lines that matter:

```python
pre = preprocess.Preprocessor("./tokenizer")                        # at import
features = pre.encode(texts)                                        # in predict()
results = preprocess.Preprocessor.decode(outputs["probabilities"])  # in predict()
```

### 7.4 — Containerise it

Three files to create, all in `/workspace/api`.

**`requirements.txt`** — the Python packages the API needs. `pip` reads it during the build,
so it has to exist on disk first:

```bash
cd /workspace/api

cat > requirements.txt <<'EOF'
flask==3.0.3
gunicorn==22.0.0
requests==2.32.3
transformers==4.44.2
numpy==1.26.4
EOF

cat requirements.txt
```

Pinned exactly — `==` means "this version, nothing newer".

**`Dockerfile`** — no extension, so `docker build` finds it without being told. Dependencies
go **before** application code, so the slow layer stays cached when you edit `app.py`:

```bash
cat > Dockerfile <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY preprocess.py app.py ./
COPY tokenizer ./tokenizer
ENV SERVING_URL=http://localhost:8501 MODEL_NAME=sentiment PYTHONUNBUFFERED=1
EXPOSE 5000
CMD ["gunicorn","--bind","0.0.0.0:5000","--workers","2","--threads","4", \
     "--worker-class","gthread","--timeout","30","--access-logfile","-","app:app"]
EOF

cat Dockerfile
```

**`.dockerignore`** — keeps scratch files out of the build context, same as Lab 6. It must
sit in `/workspace/api`, the directory you build from:

```bash
cat > .dockerignore <<'EOF'
**/__pycache__
*.pyc
.ipynb_checkpoints
EOF

ls -a
```

`ls -a` (not plain `ls` — the leading dot hides it) should now show `.dockerignore`,
`Dockerfile`, `app.py`, `preprocess.py`, `requirements.txt` and `tokenizer`. Those are
everything the build needs.

**Build.** The trailing `.` means "use this directory as the build context":

```bash
docker build -t sentiment-api:v1 .
```

Takes about 20 seconds. Every dependency has a prebuilt wheel, so nothing compiles.

### 7.5 — Run them together

Create `compose.yaml` in `/workspace/api`. **YAML is whitespace-sensitive** — every space in
this block matters, which is exactly why you paste it rather than retype it:

```bash
cd /workspace/api

cat > compose.yaml <<'EOF'
services:
  serving:
    image: sentiment-serving:v2
    expose:
      - "8501"
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/8501"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 15s
  api:
    image: sentiment-api:v1
    ports:
      - "5000:5000"
    environment:
      SERVING_URL: http://serving:8501
    depends_on:
      serving:
        condition: service_healthy
EOF
```

Check the file parses before Compose has to. `docker compose config` reads it and prints it
back, or reports the exact line where the indentation is wrong:

```bash
docker compose config
```

> The healthcheck uses **bash `/dev/tcp`, not curl** — the `tensorflow/serving` image has no
> curl, wget or python. A curl-based check can never pass, and because `api` waits on
> `service_healthy`, it would never start at all.

```bash
docker rm -f serving 2>/dev/null
docker compose up -d
docker compose ps
```

**Expected:** `serving` shows `(healthy)`, `api` shows `Up`. If `serving` reads
`(starting)`, wait a few seconds and run `docker compose ps` again.

**Wait for the model before sending anything.** A container being up is not the same as the
model being loaded — that is what `/readyz` is for. This polls every 3 seconds and gives up
after a minute:

```bash
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/readyz)
  echo "attempt $i: HTTP $code"
  [ "$code" = "200" ] && break
  sleep 3
done
```

It normally turns 200 within 15–30 seconds.

### 7.6 — Use it the way a real client would

```bash
curl -s -X POST http://localhost:5000/predict \
  -H 'Content-Type: application/json' \
  -d '{"text": ["this movie was a masterpiece", "i want those two hours back"]}' \
  | python3 -m json.tool
```

**Expected:**

```json
{ "predictions": [ {"label": "positive", "confidence": 0.997},
                   {"label": "negative", "confidence": 0.669} ],
  "sequence_length": 16,
  "timing": {"preprocess_ms": 1.42, "inference_ms": 664.23, "total_ms": 665.91} }
```

Text in, labels out. That is the product.

### 7.7 — Liveness vs readiness

```bash
docker compose stop serving
curl -s -w " [%{http_code}]\n" http://localhost:5000/healthz   # 200 — still alive
curl -s -w " [%{http_code}]\n" http://localhost:5000/readyz    # 503 — can't serve
docker compose start serving
```

One says *"should I be restarted?"*, the other says *"should I get traffic?"* Conflating
them gives you a restart loop on top of your original outage.

### 7.8 — Where does the time go?

```bash
for n in 1 2 4 8 16 32; do
  payload=$(python3 -c "import json;print(json.dumps({'text':['this film was surprisingly good']*$n}))")
  echo -n "batch $n: "
  curl -s -X POST http://localhost:5000/predict -H 'Content-Type: application/json' \
    -d "$payload" | python3 -c "import sys,json;print(json.load(sys.stdin)['timing'])"
done
```

Typical warm numbers on this hardware:

| Batch | Preprocess | Inference |
|---:|---:|---:|
| 1 | 0.37 ms | 25.71 ms |
| 8 | 1.20 ms | 83.18 ms |
| 32 | 3.10 ms | 260.25 ms |

**Tokenisation is nearly free; inference dominates by ~70×.** Every millisecond worth
optimising is in the model or the network.

Now vary length instead of count — you should see latency rise in **steps** (16 → 32 → 64 →
128 tokens), not smoothly. That is the sequence bucketing from Day 1 working: a 20-token
input and a 30-token input both pad to 32 and cost the same.

### ✅ Checkpoint

- [ ] `POST /predict` returns labels for raw text
- [ ] `/readyz` returns 503 with serving stopped; `/healthz` stays 200
- [ ] You have the batch-size and sequence-length tables written down
- [ ] Both images exist: `sentiment-serving:v2` and `sentiment-api:v1`

```bash
docker compose down
```

---

## Lab 8 — Deploy to ECR and ECS

**Full guide:** [`Lab8_ECR_and_ECS_Deployment.md`](Lab8_ECR_and_ECS_Deployment.md)
**You finish with:** your model serving public traffic from AWS Fargate.

### 8.1 — Push your images to ECR

```bash
source ~/day2-config.sh && day2_check

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_HOST"

docker tag sentiment-serving:v2 "${SERVING_REPO}:${IMAGE_TAG}"
docker tag sentiment-api:v1     "${API_REPO}:${IMAGE_TAG}"

docker push "${SERVING_REPO}:${IMAGE_TAG}"
docker push "${API_REPO}:${IMAGE_TAG}"
```

Everyone shares two repositories and is distinguished by **image tag** — your tag is your
PAX ID. Pushes take about 30s and 15s.

Compare what ECR reports against what Docker reports:

```bash
aws ecr describe-images --repository-name day2/tf-serving \
  --image-ids imageTag="$IMAGE_TAG" \
  --query 'imageDetails[0].imageSizeInBytes'
```

~349 MB, against ~1 GB locally. **ECR reports compressed layers; `docker images` reports
uncompressed on disk.** The compressed number is what crosses the network on every task
start, which makes it the one that matters.

### 8.2 — Write the task definition

Note the heredoc marker here: `<<EOF` **without quotes**. That tells the shell to substitute
your variables — `${TASK_FAMILY}`, `${EXEC_ROLE_ARN}` and the rest — as it writes the file,
so the JSON on disk holds your real values. Run `day2_check` first; empty variables here
produce a file that fails later in ways that are hard to read.

Paste the whole block, final `EOF` included:

```bash
mkdir -p /workspace/deploy && cd /workspace/deploy

cat > taskdef.json <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "3072",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "serving",
      "image": "${SERVING_REPO}:${IMAGE_TAG}",
      "essential": true,
      "portMappings": [{"containerPort": 8501, "protocol": "tcp"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "${PAX}-serving"
        }
      }
    },
    {
      "name": "api",
      "image": "${API_REPO}:${IMAGE_TAG}",
      "essential": true,
      "portMappings": [{"containerPort": 5000, "protocol": "tcp"}],
      "environment": [
        {"name": "SERVING_URL", "value": "http://localhost:8501"},
        {"name": "MODEL_NAME", "value": "sentiment"}
      ],
      "dependsOn": [{"containerName": "serving", "condition": "START"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "${PAX}-api"
        }
      }
    }
  ]
}
EOF
```

Confirm the substitution happened — no `${...}` should survive in the file:

```bash
cat taskdef.json
grep -c '\${' taskdef.json     # must print 0
```

Anything other than 0 means a variable was empty. Run `source ~/day2-config.sh && day2_check`,
then re-paste the whole heredoc — `cat >` overwrites, so there is nothing to clean up.

Three things in it to understand:

- **`SERVING_URL` is `http://localhost:8501`, not `http://serving:8501`.** Containers in one
  task share a network namespace. This is the single most common mistake moving from Compose
  to ECS.
- **`cpu: 1024` = 1 vCPU, `memory: 3072` = 3 GB.** Fargate only accepts specific pairs; 1
  vCPU permits 2–8 GB.
- **Both containers are `essential`** — if either dies the whole task is replaced.

```bash
python3 -m json.tool taskdef.json > /dev/null && echo "valid JSON"
aws ecs register-task-definition --cli-input-json file://taskdef.json \
  --query 'taskDefinition.{family:family,revision:revision}'
```

### 8.3 — Create the service

```bash
aws ecs create-service \
  --cluster "$CLUSTER" --service-name "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SERVICE_SG}],assignPublicIp=ENABLED}" \
  --query 'service.{name:serviceName,status:status}'
```

> **`assignPublicIp=ENABLED` is required** — and not only so you can reach it. Without a
> public IP the task cannot pull from ECR at all, and fails with a timeout that looks like a
> permissions problem.

Watch it come up (expect `running=1` within about a minute):

```bash
watch -n 5 "aws ecs describe-services --cluster $CLUSTER --services $SERVICE_NAME \
  --query 'services[0].{running:runningCount,pending:pendingCount}'"
```

If it stays at 0 for more than three minutes, skip to [8.5](#85--reading-a-failed-deployment).

### 8.4 — Find it and call it

```bash
TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE_NAME" \
  --query 'taskArns[0]' --output text)
ENI_ID=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text)
export PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)

echo "Your endpoint: http://${PUBLIC_IP}:5000"
sed -i '/^export PUBLIC_IP=/d' ~/day2-config.sh
echo "export PUBLIC_IP=$PUBLIC_IP" >> ~/day2-config.sh
```

```bash
curl -s "http://${PUBLIC_IP}:5000/readyz"
curl -s -X POST "http://${PUBLIC_IP}:5000/predict" \
  -H 'Content-Type: application/json' \
  -d '{"text": ["this deployment actually works"]}' | python3 -m json.tool
```

**Save that IP.**

> **You will run this lookup more than once.** Every task replacement — rolling update,
> rollback, crash — gives you a new IP. If a curl that worked five minutes ago times out,
> re-run the lookup before assuming anything is broken. A real deployment puts a load
> balancer here for exactly this reason.

### 8.5 — Reading a failed deployment

This is worth more than the happy path. Three views, in order:

```bash
# 1. Service events — plain-language scheduling decisions
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE_NAME" \
  --query 'services[0].events[0:5].[createdAt,message]' --output table

# 2. Why the task stopped
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].{last:lastStatus,stopped:stoppedReason}'

# 3. What the container itself said
aws logs tail "$LOG_GROUP" --since 10m | grep "$PAX"
```

| Symptom | Cause |
|---|---|
| `CannotPullContainerError` | No public IP, or the image tag doesn't exist in ECR |
| Task starts then stops in seconds | Container crashed — read the **logs**, not the events |
| `ResourceInitializationError` on logs | Log group missing or execution role lacks permission |
| API returns 503 for ~30s after deploy | Expected — TF Serving is still loading the model |
| `invalid cpu or memory value` | Not a valid Fargate pair |

**Exercise: break it on purpose.** Work on a *copy* so your good `taskdef.json` survives.
`sed -i` rewrites the api image tag in place to one that does not exist in ECR:

```bash
cd /workspace/deploy
cp taskdef.json taskdef-broken.json
sed -i "s|${API_REPO}:${IMAGE_TAG}|${API_REPO}:does-not-exist|" taskdef-broken.json
grep -n "image" taskdef-broken.json      # confirm one line changed

aws ecs register-task-definition --cli-input-json file://taskdef-broken.json \
  --query 'taskDefinition.revision'
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" --query 'service.taskDefinition'
```

Now read the failure through all three views above — that part is the exercise. Note that
your **old task stays running** the whole time; the service never goes down. Then roll back
to the last good revision:

```bash
aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --query 'taskDefinitionArns' --output table
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "${TASK_FAMILY}:1"     # <- the good revision number
```

### 8.6 — Rolling update and rollback

**First, change something visible in `app.py`** — you need proof that the new image is the
one actually serving traffic. Add a version field to `/healthz`. `sed -i` rewrites that one
line in place:

```bash
cd /workspace/api
sed -i 's|return jsonify(status="ok"), 200|return jsonify(status="ok", version="v2"), 200|' app.py

grep -n 'jsonify(status="ok"' app.py     # must show version="v2"
```

If `grep` shows no `version="v2"`, the text did not match. Run `nano app.py`, find the
`healthz` function, edit the line by hand, then `Ctrl-O`, `Enter`, `Ctrl-X`.

**Then rebuild, tag and push:**

```bash
cd /workspace/api
docker build -t sentiment-api:v2 .
docker tag sentiment-api:v2 "${API_REPO}:${IMAGE_TAG}-v2"
docker push "${API_REPO}:${IMAGE_TAG}-v2"
```

**Now point the task definition at the new tag** — skipping this makes the whole exercise a
no-op:

```bash
cd /workspace/deploy
sed -i "s|${API_REPO}:${IMAGE_TAG}\"|${API_REPO}:${IMAGE_TAG}-v2\"|" taskdef.json
grep -n "image" taskdef.json

aws ecs register-task-definition --cli-input-json file://taskdef.json \
  --query 'taskDefinition.revision'
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY"
```

Confirm the change actually shipped rather than assuming it — the version field you added
should appear:

```bash
curl -s "http://${PUBLIC_IP}:5000/healthz"
```

If that times out, the task was replaced and the IP changed: re-run the lookup in
[8.4](#84--find-it-and-call-it).

Rollback is a **pointer change**, not a rebuild:

```bash
aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --query 'taskDefinitionArns' --output table
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "${TASK_FAMILY}:1"
```

That is why immutable revisions matter — rollback takes seconds.

### ✅ Checkpoint

- [ ] `curl http://$PUBLIC_IP:5000/predict` returns predictions
- [ ] You recorded `PUBLIC_IP`
- [ ] You broke a deployment on purpose and diagnosed it from the logs
- [ ] You performed a rollback to an earlier revision
- [ ] **The service is still running** and answering requests after the rollback

---

## When something breaks

| What you see | Why | Fix |
|---|---|---|
| `docker: permission denied` | Group membership applied after your session started | Reconnect the session, or run `newgrp docker` |
| Variables empty after reconnect | New shell, no inherited state | `source ~/day2-config.sh` — every time |
| `day2_check` reports MISSING values | Config not filled in | Ask your instructor for the pre-filled file |
| `/workspace/day2-deploy/` is empty | The model never reached this machine | **Stop and tell your instructor** — don't work around it |
| No instances listed in Session Manager | Permissions, or wrong region | Check the region reads N. Virginia; then tell your instructor |
| TF Serving won't start | Model layout wrong | Expected in Lab 6.2 — fixed in 6.3 |
| `no basic auth credentials` on push | ECR token expired (they're short-lived) | Re-run the `aws ecr get-login-password …` line |
| `CannotPullContainerError` | No public IP, or bad image tag | Confirm `assignPublicIp=ENABLED`; verify the tag exists in ECR |
| Task starts then immediately stops | Container crashed | Read CloudWatch logs, not service events |
| API 503 for ~30 seconds after deploy | TF Serving still loading | Expected — this is why `/readyz` exists |
| Endpoint stopped responding | Task was replaced, IP changed | Re-run the lookup in [8.4](#84--find-it-and-call-it) |
| `invalid cpu or memory value` | Invalid Fargate pair | 1 vCPU permits 2–8 GB |
| Endpoint unreachable from outside AWS | Security group, or task replaced | Check inbound 5000; re-run the 8.4 lookup |

---

## What you can say at the end of today

You can take a model, put it in a container, wrap an API around it, push it to a registry
and run it on managed infrastructure — and you can say where its latency actually goes,
what a failed deployment looks like from the inside, and how to roll one back.

Every one of those answers is something you did, not an assumption.

**This is not production.** Before real users you would still need TLS, a load balancer,
authentication, rate limiting, monitoring and alerting, a rollback runbook, and a model
retraining path. Naming that gap is part of the exercise.

---

*Your AWS account and everything in it is deleted at the end of the day. Do not store
anything on it you want to keep — download anything you want before you leave.*
