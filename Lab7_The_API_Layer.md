# Day 2 — Lab 7
## The API layer: turning tensors back into a product

**Time:** ~90 minutes
**Where:** your EC2 workstation
**You will finish with:** two containers running together, accepting raw text over HTTP, and
a defensible answer to the question of whether they should have been one container.

---

## 1. The gap you found in Lab 6

Lab 6 ended with a model that answers correctly and cannot be used. The gap is precise:

| What callers have | What TF Serving requires |
|---|---|
| `"this movie was terrible"` | `input_ids`, `attention_mask`, `token_type_ids` as padded integer arrays |
| An expectation of `"negative"` | Raw logits |
| No knowledge of sequence length | A padding and bucketing decision |

Something must own that translation. There are three places it could live, and the choice
has real consequences.

**In the client.** Every caller tokenizes before sending. Fastest — no extra hop — but now
every client needs the tokenizer, the vocabulary, and the bucketing logic, and they must all
upgrade in lockstep when the model changes. This is how you get a fleet of mobile apps
pinned to a model you cannot retire.

**Inside the model graph.** TensorFlow can embed text preprocessing into the SavedModel
itself. Elegant, and it eliminates the skew risk entirely. But BERT's WordPiece tokenizer is
awkward to express as graph ops, debugging becomes considerably harder, and you lose the
ability to change bucketing without re-exporting the model.

**In a service in front of the model.** One place owns the contract, clients send text,
and the tokenizer version travels with the deployment. Costs you a network hop and a process
to operate.

We are taking the third option, which is what most production systems do. But notice that
the trade-off is real and the other two are defensible in specific circumstances — this is
worth arguing about rather than accepting.

### The skew risk, named

Whatever you choose, the failure mode is the same and it is silent. If your serving
preprocessing differs from your training preprocessing in any way — a different `max_length`,
a different truncation side, a stray `.lower()` — the model does not error. It returns
confident, wrong answers.

This is why Lab 5 exported `preprocess.py` **alongside** the model rather than reimplementing
it here. You are about to use that exact file, unmodified. That discipline is the point.

---

## 2. Set up

A new Session Manager shell inherits nothing from the last one, so start by loading your
config again. Then make a working directory and copy in the two Day 1 artifacts this lab
needs — the preprocessing script and the tokenizer:

```bash
source ~/day2-config.sh && day2_check

mkdir -p /workspace/api && cd /workspace/api
cp /workspace/day2-deploy/preprocess.py .
cp -r /workspace/day2-deploy/tokenizer .
```

`cp` copies a file; `cp -r` copies a whole directory ("recursive"). The trailing `.` means
"into the directory I am in now". Note that these are **copies** — Docker can only see files
underneath the directory you build from, which is why the artifacts come here rather than
being referenced where they sit.

Confirm both arrived before you build anything on top of them:

```bash
ls -la
ls tokenizer/
```

You should see `preprocess.py` and a `tokenizer/` directory, and inside the tokenizer a
handful of files including `tokenizer_config.json` and `vocab.txt`. **If `tokenizer/` is
empty or missing**, stop — the API cannot start without it, and the failure arrives much
later as a container that exits on startup. Re-run the `cp -r` line, and if the source
directory is genuinely empty, tell your instructor.

Now read `preprocess.py` before you use it:

```bash
head -40 preprocess.py
```

Note the bucket boundaries and the label mapping — these are decisions Lab 5 made based on
measurements, and your API is about to inherit them.

---

## 3. The application

Create `/workspace/api/app.py`. This is the longest block in the labs — paste it in one
go, from the `cat >` line all the way down to the final `EOF` on its own line. Nothing
happens until you press Enter after that last `EOF`:

```bash
cat > /workspace/api/app.py <<'EOF'
"""Text-in, label-out API in front of TensorFlow Serving."""
import os
import time
import logging

import requests
from flask import Flask, request, jsonify

import preprocess

SERVING_URL = os.environ.get("SERVING_URL", "http://localhost:8501")
MODEL_NAME = os.environ.get("MODEL_NAME", "sentiment")
PREDICT_URL = f"{SERVING_URL}/v1/models/{MODEL_NAME}:predict"
TIMEOUT_S = float(os.environ.get("SERVING_TIMEOUT_S", "5"))

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("api")

app = Flask(__name__)

# Built once at import, not per request. Tokenizer construction is expensive
# and thread-safe to share. Preprocessor loads the tokenizer itself from the
# directory you pass it - that is why there is no AutoTokenizer here.
log.info("loading tokenizer")
pre = preprocess.Preprocessor("./tokenizer")
log.info("tokenizer ready")


@app.get("/healthz")
def healthz():
    # Liveness: is this process alive? Deliberately does NOT check TF Serving.
    # If it did, a serving blip would cause the orchestrator to kill a
    # perfectly healthy API container.
    return jsonify(status="ok"), 200


@app.get("/readyz")
def readyz():
    # Readiness: can this process actually serve traffic? This one DOES check
    # the dependency, because an API that cannot reach the model should be
    # taken out of the load balancer rotation without being restarted.
    try:
        r = requests.get(f"{SERVING_URL}/v1/models/{MODEL_NAME}", timeout=2)
        if r.status_code == 200:
            return jsonify(status="ready"), 200
        return jsonify(status="model_unavailable", code=r.status_code), 503
    except Exception as exc:
        return jsonify(status="unreachable", error=str(exc)), 503


@app.post("/predict")
def predict():
    t0 = time.perf_counter()
    payload = request.get_json(silent=True) or {}
    texts = payload.get("text")

    if texts is None:
        return jsonify(error="body must contain 'text'"), 400
    if isinstance(texts, str):
        texts = [texts]
    if not isinstance(texts, list) or not all(isinstance(t, str) for t in texts):
        return jsonify(error="'text' must be a string or list of strings"), 400
    if len(texts) > 64:
        return jsonify(error="batch too large, maximum 64"), 413

    # --- preprocess (the Day 1 contract, unmodified) ---
    # Returns exactly the three tensors the signature wants, as int32 arrays,
    # already padded to the smallest bucket that fits.
    t_pre = time.perf_counter()
    features = pre.encode(texts)
    pre_ms = (time.perf_counter() - t_pre) * 1000

    body = {
        "signature_name": "serving_default",
        "inputs": {k: v.tolist() for k, v in features.items()},
    }

    # --- inference ---
    t_inf = time.perf_counter()
    try:
        resp = requests.post(PREDICT_URL, json=body, timeout=TIMEOUT_S)
    except requests.Timeout:
        log.warning("serving timeout after %.1fs", TIMEOUT_S)
        return jsonify(error="model timeout"), 504
    except requests.RequestException as exc:
        log.error("serving unreachable: %s", exc)
        return jsonify(error="model unreachable"), 503
    inf_ms = (time.perf_counter() - t_inf) * 1000

    if resp.status_code != 200:
        log.error("serving returned %s: %s", resp.status_code, resp.text[:300])
        return jsonify(error="model error", detail=resp.text[:300]), 502

    outputs = resp.json().get("outputs", {})

    # --- postprocess ---
    # decode() is a staticmethod and takes the probabilities array only - not
    # the whole outputs dict, and not the original texts. TF Serving returns
    # outputs = {"logits": [...], "probabilities": [...], "predicted_class": [...]}
    results = preprocess.Preprocessor.decode(outputs["probabilities"])
    total_ms = (time.perf_counter() - t0) * 1000

    log.info("n=%d seq_len=%d pre=%.1fms inf=%.1fms total=%.1fms",
             len(texts), features["input_ids"].shape[1], pre_ms, inf_ms, total_ms)

    return jsonify(
        predictions=results,
        timing={"preprocess_ms": round(pre_ms, 2),
                "inference_ms": round(inf_ms, 2),
                "total_ms": round(total_ms, 2)},
        sequence_length=int(features["input_ids"].shape[1]),
    ), 200


if __name__ == "__main__":
    # Development only. Production uses gunicorn - see the Dockerfile.
    app.run(host="0.0.0.0", port=5000)
EOF
```

Check it arrived intact before going any further. `wc -l` counts lines and `tail -3` shows
the end of the file — if the paste was truncated, this is where you find out, rather than
sixty seconds into a Docker build:

```bash
cd /workspace/api
wc -l app.py
tail -3 app.py
python3 -c "import ast; ast.parse(open('app.py').read()); print('app.py parses cleanly')"
```

The last line asks Python to read the file as code without running it. If it reports a
`SyntaxError`, the paste was cut short — re-paste the whole block; `cat >` overwrites, so
there is nothing to clean up first.

### Three things in that file worth pausing on

**The timing breakdown in the response** is not decoration. It tells you whether your
latency is dominated by tokenization or inference, and you cannot optimise what you have not
separated. Most people are surprised by the answer.

**`/healthz` and `/readyz` are different on purpose.** Liveness answers "should I be
restarted?" Readiness answers "should I receive traffic?" Conflating them produces a
memorable outage: TF Serving hiccups, the liveness probe fails, the orchestrator restarts
the API container, which does nothing to fix TF Serving, and now you have a restart loop on
top of your original problem.

**Every failure mode returns a distinct status code.** 504 for timeout, 503 for unreachable,
502 for a model error, 400 and 413 for bad input. When this is behind a load balancer at 3am,
those codes are the difference between a five-minute diagnosis and an hour of guessing.

### Check preprocess.py's interface — before you build anything

`app.py` above is written against the interface `preprocess.py` actually exposes: a
**class**, not module-level functions. Confirm that for yourself rather than trusting it —
this is the single most likely thing to have drifted since Lab 5, and it fails for
everyone at once:

```bash
cd /workspace/api
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

You should see no module-level functions and a `Preprocessor` class with
`__init__(self, tokenizer_dir)`, `encode(self, texts)` and a static
`decode(probabilities)`. That is what the three marked lines in `app.py` are calling.

**If your output differs, adapt `app.py` — do not rewrite `preprocess.py`.** That file is
the training-serving contract, and editing it to fit your API is exactly how the silent
skew described in §1 gets introduced.

Two mistakes to avoid if you do adapt it:

- `encode` takes **only** `texts`. The preprocessor already holds the tokenizer, so
  passing one in is a `TypeError`.
- `decode` takes **only the probabilities array**. Passing the whole `outputs` dict does
  not raise cleanly — it indexes the dict and returns confident nonsense, which is the
  worst failure mode in this lab.

---

## 4. Containerise it

### Create `/workspace/api/requirements.txt`

This file lists the Python packages the API needs. `pip` reads it inside the build, so it has
to exist on disk *before* you build. Same heredoc pattern as always — paste the whole block,
closing `EOF` included:

```bash
cd /workspace/api

cat > requirements.txt <<'EOF'
flask==3.0.3
gunicorn==22.0.0
requests==2.32.3
transformers==4.44.2
numpy==1.26.4
EOF
```

Read it back:

```bash
cat requirements.txt
```

Five lines, one package each. Pinned exactly — `==` means "this version, nothing newer", so
the image you build next month is the image you built today. `transformers` here pulls only
the tokenizer stack — no PyTorch, no TensorFlow — which is why this image stays small.

### Create `/workspace/api/Dockerfile`

This one is named `Dockerfile` with no extension, so `docker build` finds it without being
told:

```bash
cat > /workspace/api/Dockerfile <<'EOF'
FROM python:3.11-slim

WORKDIR /app

# Dependencies first: this layer is cached and only rebuilds when
# requirements.txt changes. Copying the application code first would
# re-install every dependency on every code edit.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY preprocess.py app.py ./
COPY tokenizer ./tokenizer

ENV SERVING_URL=http://localhost:8501 \
    MODEL_NAME=sentiment \
    PYTHONUNBUFFERED=1

EXPOSE 5000

# gthread: this process spends most of its time waiting on TF Serving, so
# threads give concurrency cheaply. Tokenisation is the CPU-bound part and
# releases the GIL only partially - tune these numbers against real
# measurements rather than trusting them.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", \
     "--workers", "2", "--threads", "4", "--worker-class", "gthread", \
     "--timeout", "30", "--access-logfile", "-", "app:app"]
EOF
```

Read the Dockerfile back before building — a Dockerfile that got truncated mid-paste fails
in confusing ways:

```bash
cat Dockerfile
```

### Create `/workspace/api/.dockerignore`

Same job as the one in Lab 6: keep junk out of the build context. It must sit in
`/workspace/api`, the directory you build from — a `.dockerignore` anywhere else is silently
ignored:

```bash
cd /workspace/api

cat > .dockerignore <<'EOF'
**/__pycache__
*.pyc
.ipynb_checkpoints
EOF
```

The leading dot makes it hidden, so confirm it with `ls -a` rather than plain `ls`:

```bash
ls -a
cat .dockerignore
```

You should see `.dockerignore` alongside `app.py`, `Dockerfile`, `preprocess.py`,
`requirements.txt` and `tokenizer`. Those five are what the build needs; everything else in
the listing is noise the file keeps out.

### Build

The trailing `.` means "build using this directory as the context":

```bash
cd /workspace/api
docker build -t sentiment-api:v1 .
docker images | grep -E "sentiment-(api|serving)"
```

Roughly 20 seconds — every dependency has a prebuilt wheel, so nothing compiles. The `grep`
should list both `sentiment-api:v1` and `sentiment-serving:v2`.

**Exercise 7.1.** Edit one line in `app.py`, rebuild, and time it. Then edit
`requirements.txt`, rebuild, and time that. The difference is the layer cache doing its job —
and the reason dependency-before-code ordering is a rule rather than a preference.

Wrap each build in `time` so you get a number rather than an impression. `time` prints how
long the command took; read the `real` line.

First, a code edit. `>>` appends a comment to the end of `app.py` — harmless, but enough to
change the file:

```bash
cd /workspace/api
echo "# cache test" >> app.py
time docker build -t sentiment-api:v1 .
```

Now a dependency edit. Adding a trailing blank comment line to `requirements.txt` changes the
file `pip` reads, which invalidates that layer and everything below it:

```bash
echo "# cache test" >> requirements.txt
time docker build -t sentiment-api:v1 .
```

A reference run gave **0.4 s** for the code edit against **28 s** for the requirements edit:
the same image, built the same way, roughly seventy times slower because one changed line
invalidated the `pip install` layer and every layer after it.

Undo both edits so you carry a clean file into Lab 8, and rebuild once more:

```bash
sed -i '/^# cache test$/d' app.py requirements.txt
tail -2 app.py requirements.txt
docker build -t sentiment-api:v1 .
```

---

## 5. Run them together

Two containers must reach each other. Compose is the tool that starts both and puts them on a
shared private network.

**First, a pre-flight check.** Compose is about to start its own copy of the model server, so
confirm the image exists and clear away the standalone container Lab 6 left running:

```bash
docker images sentiment-serving        # sentiment-serving:v2 must be listed
docker rm -f serving 2>/dev/null       # remove Lab 6's container; harmless if it is gone
docker ps                              # should list nothing
```

If `sentiment-serving:v2` is missing, go back to Lab 6 §4 and build it. Leaving Lab 6's
container running is not a port clash — Compose keeps 8501 internal — but it is a second copy
of TF Serving competing for the same two vCPUs, which quietly distorts every timing you take
in §6. The `2>/dev/null` on the middle line hides the "no such container" message when there
is nothing to remove.

Now create `/workspace/api/compose.yaml`:

```bash
cat > /workspace/api/compose.yaml <<'EOF'
services:
  serving:
    image: sentiment-serving:v2
    expose:
      - "8501"
    healthcheck:
      # The tensorflow/serving image ships no curl, no wget and no python. It
      # does have bash, so use bash's /dev/tcp to test that the port is open.
      # A curl-based check here can never pass, and because the api container
      # waits on service_healthy, it would never start at all.
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
      # Compose gives each service a DNS name on the shared network.
      SERVING_URL: http://serving:8501
    depends_on:
      serving:
        condition: service_healthy
EOF
```

YAML is whitespace-sensitive, so confirm the file is valid before Compose tries to read it —
`config` parses the file and prints it back, and prints an error with a line number if the
indentation is wrong:

```bash
cd /workspace/api
docker compose config
```

Then start both containers. `-d` means "detached": they run in the background and you get
your prompt back instead of a wall of logs:

```bash
cd /workspace/api
docker compose up -d
docker compose ps
```

**Expected** — the service names come from the directory name, so `api-` is the prefix:

```
NAME            IMAGE                  STATUS
api-api-1       sentiment-api:v1       Up 8 seconds
api-serving-1   sentiment-serving:v2   Up 20 seconds (healthy)
```

`serving` must read **(healthy)** — the `api` container refuses to start until it does. If it
reads `(starting)`, wait and re-run `docker compose ps`; if it reads `(unhealthy)` after a
minute, jump to the failure table at the end of this section.

**Wait for the model before you send anything.** The container being up is not the same as
the model being loaded — that is the whole point of `/readyz`. This loop polls it every three
seconds and gives up after a minute:

```bash
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/readyz)
  echo "attempt $i: HTTP $code"
  [ "$code" = "200" ] && break
  sleep 3
done
```

It usually turns 200 within 15–30 seconds. To watch what the API is doing while you work, in
a spare moment:

```bash
docker compose logs -f api        # Ctrl-C to stop following
```

Note that `serving` publishes no port to the host. Only the API is reachable from outside.
That is the correct posture: the model server is an internal dependency, not a public
endpoint.

**The healthcheck is weaker than it looks, and that is worth naming.** `/dev/tcp` proves
the port is *open*, not that the model is *loaded* — TF Serving binds 8501 before the
SavedModel finishes loading. So the api container can start a second or two before serving
can actually answer, which is precisely why `/readyz` exists and why the first request
after a cold start may still 503. A stricter check would need a HTTP client inside the
serving image; adding one costs image size on every task pull, for a guarantee `/readyz`
already gives you at the layer that matters. Knowing *which* guarantee a probe actually
provides is the point.

**Now use it the way a real client would:**

```bash
curl -s -X POST http://localhost:5000/predict \
  -H 'Content-Type: application/json' \
  -d '{"text": ["this movie was a masterpiece", "i want those two hours back"]}' \
  | python3 -m json.tool
```

**Expected** — two predictions in the order you sent them:

```json
{
    "predictions": [
        {"label": "positive", "confidence": 0.997},
        {"label": "negative", "confidence": 0.669}
    ],
    "sequence_length": 16,
    "timing": {"preprocess_ms": 1.42, "inference_ms": 664.23, "total_ms": 665.91}
}
```

Your confidences will differ slightly and your timings will differ a lot. If this is the
first prediction since the container started, `inference_ms` will be anywhere from several
hundred to over a thousand milliseconds — TF Serving initialises lazily on its first
inference. Send the identical request again and watch it fall to roughly 50 ms. That gap is
why §6 opens with a throwaway warm-up request.

Text in, labels out. That is the product. Compare it against the raw token-ID array you had
to hand-write at the end of Lab 6.

Now the two probes. `-w` appends the HTTP status code, which is the part that matters here
and is invisible in the response body:

```bash
curl -s -w ' [%{http_code}]\n' http://localhost:5000/healthz
curl -s -w ' [%{http_code}]\n' http://localhost:5000/readyz
```

**Expected** — both 200 while everything is running:

```
{"status":"ok"} [200]
{"status":"ready"} [200]
```

**Exercise 7.2.** Stop the model server and watch the two probes disagree:

```bash
docker compose stop serving

curl -s -w ' [%{http_code}]\n' http://localhost:5000/healthz    # still 200
curl -s -w ' [%{http_code}]\n' http://localhost:5000/readyz     # now 503
```

`/healthz` stays `200` — the API process is alive and should not be restarted. `/readyz`
returns `503` with `{"status":"unreachable", ...}` — it cannot serve, so a load balancer
should stop sending it traffic. Explain to your neighbour why that asymmetry is what you
want, then start it again before moving on:

```bash
docker compose start serving
```

### If something is not working

Read the API's own logs first — `docker compose logs api` — then match the symptom here:

| What you see | What it means | Fix |
|---|---|---|
| `no configuration file provided` | You are not in the directory holding `compose.yaml` | `cd /workspace/api` |
| `port is already allocated` on 5000 | An API container from an earlier attempt is still up | `docker ps`, then `docker rm -f <name>` |
| Logs show `ModuleNotFoundError: No module named 'preprocess'` | `preprocess.py` never made it into the image | Check the `COPY preprocess.py app.py ./` line in the Dockerfile, then rebuild |
| Logs show an error loading `./tokenizer` | The tokenizer directory was empty or missing at build time | Redo the `cp -r` in §2, then rebuild |
| `api` container never starts | `serving` never reported healthy, and `api` waits on it | `docker compose logs serving` — the model layout is the usual cause |
| `/predict` returns 503 `model unreachable` | The API cannot reach the model server | Confirm `SERVING_URL` is `http://serving:8501` in `compose.yaml`, not `localhost` |
| `/predict` returns 504 `model timeout` | Inference took longer than 5 seconds | Usually a cold first request under load — retry once |
| First request takes ~1200 ms | TF Serving initialises lazily on its first inference | Expected. Send a throwaway request first — see §6 |

Nothing here needs a rebuild of `sentiment-serving:v2`. If you do rebuild the API image,
`docker compose up -d` picks up the new image; it does not need a `down` first.

---

## 6. Where does the time actually go?

**Send one throwaway request first.** TF Serving does lazy initialisation on its first
inference, so a cold request costs around 1200 ms against roughly 50 ms warm. Exercise 7.2
just restarted the serving container, so without this your `batch 1` row absorbs that
cold start and every conclusion you draw from the table is wrong:

```bash
curl -s -o /dev/null -X POST http://localhost:5000/predict \
  -H 'Content-Type: application/json' -d '{"text": "warmup"}'
```

Now vary the **number** of texts per request. The loop runs once for each value of `n`,
builds a JSON body containing that many copies of the same sentence, posts it, and prints
just the `timing` block from the response:

```bash
for n in 1 2 4 8 16 32; do
  payload=$(python3 -c "import json;print(json.dumps({'text':['this film was surprisingly good']*$n}))")
  echo -n "batch $n: "
  curl -s -X POST http://localhost:5000/predict -H 'Content-Type: application/json' \
    -d "$payload" | python3 -c "import sys,json;t=json.load(sys.stdin)['timing'];print(t)"
done
```

**Expected shape** — one line per batch size, preprocessing tiny throughout and inference
climbing roughly with the batch. A reference run:

| Batch | `preprocess_ms` | `inference_ms` |
|---:|---:|---:|
| 1 | 0.37 | 25.71 |
| 8 | 1.20 | 83.18 |
| 32 | 3.10 | 260.25 |

Tokenisation is nearly free; inference dominates by roughly 70× at batch size 1. That is the
answer to "where would optimisation actually pay" — and it is not in the Python.

Then vary length rather than count. `reps` is how many times the four-word phrase is
repeated, **not** a word count — the values below are chosen to land one measurement in each
of the four buckets `preprocess.py` defines (16, 32, 64, 128):

```bash
for reps in 2 5 11 20 30; do
  text=$(python3 -c "print('the film was interesting '*$reps)")
  echo -n "reps=$reps: "
  curl -s -X POST http://localhost:5000/predict -H 'Content-Type: application/json' \
    -d "{\"text\": [\"$text\"]}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('seq', d['sequence_length'], d['timing'])"
done
```

The `sequence_length` column should read `16, 32, 64, 128, 128` — and that repeated `128` is
the most instructive row in the table. `reps=30` is half as much text again as `reps=20`, and
it costs the same, because both pad to the same bucket.

**Exercise 7.3.** Record both tables. Answer three questions from your own numbers: does
preprocessing or inference dominate at batch size 1? Which one grows faster with batch size?
And does the bucketing from `preprocess.py` show up as visible steps in latency as text gets
longer?

That last one is the payoff from Lab 5. You should see a step at each bucket boundary and a
flat stretch between them, rather than a smooth curve — you are paying for 32 tokens or 64
tokens, not for every token in between. A reference run on a `t3.large` gave roughly
39 / 63 / 76 / 115 / 112 ms across those five rows.

---

## 7. The decision: one container or two?

You have built two. Argue the other side.

**One container** — gunicorn and TF Serving in the same image, started by a supervisor.
Simpler deployment, one artifact to version, no inter-process hop, and no possibility of the
API and model versions drifting apart. Against it: two processes with one lifecycle, so
neither can restart independently, and you cannot scale the CPU-hungry model separately from
the cheap API.

**Two containers, one task** — what you will deploy in Lab 8. They share a network namespace,
so `localhost` works between them and the hop costs almost nothing. They start and stop
together, but each can crash and restart independently. Version skew is prevented by the task
definition pinning both image tags together.

**Two services** — separately deployed and scaled, API talking to serving over a load
balancer. Maximum flexibility, and now you own service discovery, an extra network hop with
real latency, and a genuine distributed-systems problem. This is right when many different
APIs share one model, and overkill otherwise.

**Exercise 7.4.** Pick one and write two sentences defending it for *this* workload — a
single model, one client type, and traffic that Day 1 measured. There is a defensible answer
for each. The indefensible move is choosing without articulating the trade.

Lab 8 uses two containers in one task, because it gives independent restart and clean
separation without inventing a distributed system for a problem that does not have one.

---

## 8. Clean up

`docker compose down` stops both containers and removes them along with the private network
Compose created. It must run from the directory holding `compose.yaml`:

```bash
cd /workspace/api
docker compose down
docker ps
```

`docker ps` should list nothing. Your **images** are untouched — `down` removes containers,
not images — which matters because Lab 8 pushes `sentiment-serving:v2` and
`sentiment-api:v1` to ECR. Confirm they survived:

```bash
docker images | grep -E "sentiment-(api|serving)"
```

---

## What you built

- A text-in, label-out API that reuses the Day 1 preprocessing contract unmodified
- Liveness and readiness probes that answer different questions
- Distinct error codes for every downstream failure mode
- Two containers composed on a private network, with only the API exposed
- Measurements separating preprocessing cost from inference cost

## Checklist before moving on

- [ ] `POST /predict` returns labels for raw text
- [ ] `/readyz` reports 503 when serving is stopped; `/healthz` stays 200
- [ ] You have the batch-size and sequence-length timing tables written down
- [ ] Both images exist locally: `sentiment-serving:v2` and `sentiment-api:v1`
- [ ] You can state, in one sentence, why the tokenizer ships in the API image

## Discussion

1. The tokenizer is in the API image; the model is in the serving image. What breaks if
   someone updates one without the other, and how would you prevent it mechanically?
2. `--workers 2 --threads 4` was asserted, not measured. What would you need to observe to
   justify or change it?
3. Your API caps batches at 64. Where should that limit really come from?
