# Day 2 — Lab 8
## Deploying to AWS: ECR and ECS Fargate

**Time:** ~90 minutes
**Where:** your EC2 workstation
**You will finish with:** your model serving public traffic from a managed AWS service, and
the ability to read a failed deployment rather than guess at it.

---

## 1. What changes when you leave your workstation

Locally, Docker Compose gave you a network, DNS between containers, restart handling and
port publishing. On AWS those responsibilities split across services, and knowing which does
what is most of the learning here.

| Local | AWS | What it owns |
|---|---|---|
| `docker build` | Same, on this box | Producing the image |
| Local image store | **ECR** | Storing and distributing images |
| `compose.yaml` | **Task definition** | What runs, with which resources and env |
| `docker compose up` | **ECS service** | Keeping N copies running, replacing failures |
| The host itself | **Fargate** | Providing the compute, with no servers to manage |
| `docker logs` | **CloudWatch Logs** | Collecting output from ephemeral tasks |

**Why Fargate rather than the EC2 launch type:** with EC2 you would also manage a cluster of
instances — capacity, scaling, patching, bin-packing tasks onto hosts. Fargate runs each task
on compute AWS provisions for it. You pay more per vCPU-hour and you give up control you do
not need today.

### The one concept to hold on to

A task definition describes **containers that run together as a unit**. Containers in the
same task share a network namespace. That means your API container reaches TF Serving at
`http://localhost:8501` — not by a service name, as in Compose. Same machine, same network
stack, two processes.

---

## 2. Set up

```bash
source ~/day2-config.sh && day2_check
```

Every value must be populated. `EXEC_ROLE_ARN` and `SUBNET_ID` in particular are needed
before anything in section 4 will work.

---

## 3. Push to ECR

Authenticate Docker against your account's registry. The token is short-lived, so expect to
re-run this if you come back after a long break:

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_HOST"
```

Everyone shares two repositories and is distinguished by **image tag**:

```bash
docker tag sentiment-serving:v2 "${SERVING_REPO}:${IMAGE_TAG}"
docker tag sentiment-api:v1     "${API_REPO}:${IMAGE_TAG}"

docker push "${SERVING_REPO}:${IMAGE_TAG}"
docker push "${API_REPO}:${IMAGE_TAG}"
```

Watch the push output. Layers already present in the registry are skipped — with twenty
people pushing images built from the same base, most of the bytes only travel once. That is
content-addressed layer storage doing real work.

Confirm:

```bash
aws ecr describe-images --repository-name day2/tf-serving \
  --image-ids imageTag="$IMAGE_TAG" \
  --query 'imageDetails[0].{size:imageSizeInBytes,pushed:imagePushedAt}'
```

**Exercise 8.1.** Compare `imageSizeInBytes` here against `docker images` locally. They
differ. Work out why before reading the footnote at the end of this lab.

---

## 4. Write the task definition

You are creating a file called `taskdef.json`. One thing differs from every heredoc so far:
the closing marker is written `<<EOF` **without quotes**. That tells the shell to substitute
your variables — `${TASK_FAMILY}`, `${EXEC_ROLE_ARN}` and the rest — as it writes the file,
so the JSON that lands on disk contains your real values rather than the literal text
`${TASK_FAMILY}`. Run `day2_check` first if you have not already; empty variables here
produce a file that registers and then fails in ways that are hard to read.

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

python3 -m json.tool taskdef.json > /dev/null && echo "valid JSON"
```

That last line parses the file and prints `valid JSON` only if it is. Now read the file back
and check the substitution actually happened — no `${...}` should survive anywhere in it:

```bash
cat taskdef.json
grep -c '\${' taskdef.json     # must print 0
```

If `grep` prints anything other than 0, some variable was empty when you pasted the block.
Fix it with `source ~/day2-config.sh && day2_check`, then re-paste the whole heredoc — `cat >`
overwrites, so there is nothing to delete first.

### Read before you register

**`SERVING_URL` is `localhost`, not `serving`.** This is the shared network namespace in
action, and it is the single most common mistake when moving from Compose to ECS.

**`cpu: 1024` is 1 vCPU; `memory: 3072` is 3 GB.** Fargate only accepts specific
combinations — 1 vCPU permits 2 through 8 GB. An invalid pair is rejected at registration
with a message that is clearer than most.

**Both containers are `essential: true`**, so if either dies the whole task is replaced. That
is right here: an API with no model is useless, and a model with no API is unreachable.

**`dependsOn` with `START`** orders startup but does not wait for health. TF Serving takes a
few seconds to load the model, so early API requests may fail. Exercise 8.5 asks you to fix
this properly.

Register it:

```bash
aws ecs register-task-definition --cli-input-json file://taskdef.json \
  --query 'taskDefinition.{family:family,revision:revision}'
```

Revisions are immutable and numbered. You never edit a task definition — you register a new
revision and point the service at it. That is what makes rollback a one-line operation.

---

## 5. Create the service

```bash
aws ecs create-service \
  --cluster "$CLUSTER" \
  --service-name "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SERVICE_SG}],assignPublicIp=ENABLED}" \
  --query 'service.{name:serviceName,status:status,desired:desiredCount}'
```

**`assignPublicIp=ENABLED` is required**, and not only so you can reach it. Fargate tasks in a
public subnet need a public IP to pull from ECR at all. Without it, tasks fail during image
pull with a timeout that looks like a networking problem because it is one. This is the most
common Fargate failure in training environments.

Watch it come up:

```bash
watch -n 5 "aws ecs describe-services --cluster $CLUSTER --services $SERVICE_NAME \
  --query 'services[0].{running:runningCount,pending:pendingCount,desired:desiredCount}'"
```

`Ctrl-C` once `running` reaches 1. If it stays at 0 for more than three minutes, go to
section 7 — do not wait longer, because a task that is going to start has already started.

---

## 6. Find it and call it

Fargate tasks get an ENI with a public IP. Two lookups:

```bash
TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE_NAME" \
  --query 'taskArns[0]' --output text)

ENI_ID=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" \
  --output text)

export PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)

echo "Your endpoint: http://${PUBLIC_IP}:5000"

# Replace any previous value rather than appending a new one - you will run this
# lookup again every time the task is replaced, and stale lines pile up fast.
sed -i '/^export PUBLIC_IP=/d' ~/day2-config.sh
echo "export PUBLIC_IP=$PUBLIC_IP" >> ~/day2-config.sh
```

**You will need this lookup more than once.** Any task replacement — a rolling update, a
rollback, a crash, an autoscaling event — gives you a new ENI and a new public IP. If a
curl that worked five minutes ago now times out, re-run the three commands above before
assuming anything is broken.

```bash
curl -s "http://${PUBLIC_IP}:5000/healthz"
curl -s "http://${PUBLIC_IP}:5000/readyz"

curl -s -X POST "http://${PUBLIC_IP}:5000/predict" \
  -H 'Content-Type: application/json' \
  -d '{"text": ["this deployment actually works"]}' | python3 -m json.tool
```

**Save that IP.** Every client you point at this service uses it.

Note what just happened: the model you distilled, pruned and quantised on Day 1 is now
answering requests from the public internet, on infrastructure you did not provision, from a
container you built an hour ago.

**A caveat worth stating plainly:** a raw public IP on a task is a *training* shortcut. The
IP changes whenever the task is replaced, so it is not addressable in any durable sense. Real
deployments put an Application Load Balancer in front, which gives a stable DNS name, health
check integration, and TLS termination. We are skipping it because ALB setup is a lab of its
own and teaches networking rather than deployment.

---

## 7. Reading a failed deployment

This is the skill worth more than the happy path. **Service events first** — they explain
scheduling decisions in plain language:

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE_NAME" \
  --query 'services[0].events[0:5].[createdAt,message]' --output table
```

Events tell you what the scheduler *did* — "has started 1 tasks", "has reached a steady
state". They are slow to admit failure: ECS only posts "unable to consistently start tasks"
after several minutes of retrying, so for the first few minutes a broken deployment looks
identical to a healthy one here. The reason lives in the next view.

**Then the stopped reason** on the task itself. The failed task is **not** the one you looked
up in section 6 — that one is still running, and `list-tasks` returns only running tasks
unless you ask it for stopped ones:

```bash
FAILED_TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE_NAME" \
  --desired-status STOPPED --query 'taskArns[0]' --output text)

echo "$FAILED_TASK"     # prints None if nothing has failed yet - wait and re-run

aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$FAILED_TASK" \
  --query 'tasks[0].{last:lastStatus,desired:desiredStatus,stopped:stoppedReason,containers:containers[].{name:name,reason:reason,exit:exitCode}}'
```

**Then the container's own output.** `--log-stream-name-prefix` filters to your streams in
the shared log group, server-side:

```bash
aws logs tail "$LOG_GROUP" --since 10m --follow --log-stream-name-prefix "$PAX"
```

`Ctrl-C` to stop following. Do **not** pipe this to `grep` to pick out your own lines: the
AWS CLI buffers its output when it is writing to a pipe rather than a terminal, so
`aws logs tail --follow | grep "$PAX"` sits there showing you nothing at all, which reads
exactly like "my container produced no logs". The `--log-stream-name-prefix` flag does the
same filtering without a pipe.

Common causes, in the order you will meet them:

| Symptom | Cause |
|---|---|
| `CannotPullContainerError` | No public IP, or the image tag does not exist in ECR |
| Task starts then stops within seconds | Container crashed — read the logs, not the events |
| `ResourceInitializationError` on logs | Log group missing or execution role lacks permission |
| API returns 503 for the first ~30 seconds | Expected: TF Serving is still loading the model |
| `invalid cpu or memory value` | Not a valid Fargate combination |

**Exercise 8.2.** Break it deliberately. Register a new revision with a nonexistent image
tag, update the service to it, and read the failure through all three views. Then roll back.
Doing this on purpose, once, is worth more than reading about it.

The mechanics, so the exercise is the *diagnosis* rather than the typing. Work on a copy so
your good `taskdef.json` stays intact — `sed` here rewrites the api image tag to one that
does not exist in ECR:

```bash
cd /workspace/deploy
cp taskdef.json taskdef-broken.json
sed -i "s|${API_REPO}:${IMAGE_TAG}|${API_REPO}:does-not-exist|" taskdef-broken.json

# Confirm exactly one image line was changed
grep -n "image" taskdef-broken.json
```

Register the broken copy — note it registers under the same family, so it becomes the next
revision number. Passing the family name alone to `update-service` resolves to the **latest**
revision, which is the broken one you just registered:

```bash
aws ecs register-task-definition --cli-input-json file://taskdef-broken.json \
  --query 'taskDefinition.{family:family,revision:revision}'

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" --query 'service.taskDefinition'
```

Give it a minute or two — the task has to be placed and then fail its image pull, with
retries — then diagnose it with the three commands above. That part is the exercise. Note
which view actually answers you: the events are still cheerful, the third view has no
container logs at all because no container ever started, and the whole story is in the
stopped task's `stoppedReason`. Notice too that your **old task keeps serving traffic**
throughout: ECS will not drain a healthy task for a replacement that never becomes healthy.

To recover, point the service back at the last good revision. List what exists and pick the
number, rather than assuming:

```bash
aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --query 'taskDefinitionArns' --output table

# :1 below is the good revision - use the number you actually see listed above
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "${TASK_FAMILY}:1" \
  --query 'service.taskDefinition'
```

Rolling back starts a **new** task even though the revision is one you were already running,
so your public IP changes here. If a curl stops answering after the rollback, that is the
ENI, not a failed recovery — re-run the section 6 lookup.

---

## 8. Rolling updates and rollback

### Step 1 — change something visible in `app.py`

You need a change you can *see* in a response, so you can prove the new image is the one
actually serving traffic. Add a version field to `/healthz`.

The handler currently ends with `return jsonify(status="ok"), 200`. `sed -i` rewrites that
one line in place; `s|old|new|` means substitute:

```bash
cd /workspace/api
sed -i 's|return jsonify(status="ok"), 200|return jsonify(status="ok", version="v2"), 200|' app.py

# Must print the line with version="v2" in it
grep -n 'jsonify(status="ok"' app.py
```

If `grep` shows no `version="v2"`, the text did not match exactly. Open the file with
`nano app.py`, find the `healthz` function, edit that line by hand, then `Ctrl-O` and `Enter`
to save and `Ctrl-X` to exit. Then confirm it still parses as Python:

```bash
python3 -c "import ast; ast.parse(open('app.py').read()); print('ok')"
```

### Step 2 — rebuild, tag and push

```bash
cd /workspace/api
docker build -t sentiment-api:v2 .
docker tag sentiment-api:v2 "${API_REPO}:${IMAGE_TAG}-v2"
docker push "${API_REPO}:${IMAGE_TAG}-v2"
```

**Now point the task definition at the new tag.** This step is easy to skip, and skipping
it makes the whole exercise a no-op: `update-service` would deploy the same image you are
already running, and the rollback below would have nothing to roll back to.

```bash
cd /workspace/deploy
sed -i "s|${API_REPO}:${IMAGE_TAG}\"|${API_REPO}:${IMAGE_TAG}-v2\"|" taskdef.json

# Confirm the api container - and only the api container - moved to -v2
grep -n "image" taskdef.json
```

Register that as a new revision and note the number it returns:

```bash
aws ecs register-task-definition --cli-input-json file://taskdef.json \
  --query 'taskDefinition.{family:family,revision:revision}'
```

Then point the service at it. Passing the family name alone resolves to the **latest**
revision, which is the one you just registered:

```bash
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "$TASK_FAMILY" \
  --query 'service.{taskDef:taskDefinition,desired:desiredCount}'
```

Watch the deployment. With `desired-count 1`, ECS starts the new task before draining the
old one, so you will briefly see two — one `PRIMARY` and one `ACTIVE`, then one `DRAINING`:

```bash
watch -n 5 "aws ecs describe-services --cluster $CLUSTER --services $SERVICE_NAME \
  --query 'services[0].deployments[].{td:taskDefinition,running:runningCount,status:status}'"
```

`Ctrl-C` once the only deployment left is `PRIMARY` with `running: 1` — about ninety seconds.

The new task is on a new ENI, so **your public IP has changed**. Re-run the lookup from
section 6 first, then confirm the change actually shipped rather than assuming it:

```bash
curl -s "http://${PUBLIC_IP}:5000/healthz"    # should show your new version field
```

**Rollback is pointing at the previous revision.** Check which revisions exist first —
if you did Exercise 8.2 you have registered more than you think, and the good one is not
necessarily `:1`:

```bash
aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" \
  --query 'taskDefinitionArns' --output table

# Confirm the revision you are about to roll back to has the image you expect
aws ecs describe-task-definition --task-definition "${TASK_FAMILY}:1" \
  --query "taskDefinition.containerDefinitions[?name=='api'].image | [0]"

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "${TASK_FAMILY}:1" \
  --query 'service.taskDefinition'
```

Without the `--query`, `update-service` prints the entire service object — a screenful of
JSON in which the one line you care about is easy to miss.

This is why immutable revisions matter. Rollback is not a rebuild, not a redeploy, and not a
git revert — it is a pointer change, and it takes seconds.

**Exercise 8.3.** Set `desired-count` to 2 and run a rolling update while polling `/healthz`
in a loop. Do you observe a dropped request? What would you need to change to be confident
there was none?

---

## 9. Leave it running

Leave this service alive with a public IP that still answers. Do **not** delete it before
the end of the session.

The rollback you just did replaced the task, so the `PUBLIC_IP` sitting in your shell and in
`~/day2-config.sh` is the *previous* task's — it is dead, and a curl to it fails with
`Connection reset by peer`. Look it up once more and re-record it. This is the last section
of the lab, so this is the value you finish with:

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE_NAME" \
  --query 'services[0].{running:runningCount,taskDef:taskDefinition}'

TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE_NAME" \
  --query 'taskArns[0]' --output text)

ENI_ID=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" \
  --output text)

export PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)

sed -i '/^export PUBLIC_IP=/d' ~/day2-config.sh
echo "export PUBLIC_IP=$PUBLIC_IP" >> ~/day2-config.sh

echo "Endpoint: http://${PUBLIC_IP}:5000"
```

Prove it before you walk away — an endpoint you did not curl is an endpoint you do not have:

```bash
curl -s "http://${PUBLIC_IP}:5000/healthz"    # must print {"status":"ok"}
```

---

## What you built

- Two images in ECR, distinguished by tag in a registry shared with nineteen other people
- A task definition running two containers as one unit on a shared network namespace
- An ECS Fargate service maintaining a running task on compute you never provisioned
- A public endpoint answering real requests
- The three-view diagnostic method: service events, stopped reason, container logs
- A rollback performed as a pointer change

## Checklist before moving on

- [ ] `curl http://$PUBLIC_IP:5000/predict` returns predictions
- [ ] You re-looked-up `PUBLIC_IP` *after* the rollback (§9) and curled it — every task
      replacement changes it, so the recorded IP has to be the current one
- [ ] You deliberately broke a deployment and diagnosed it from the logs (8.2)
- [ ] You performed a rollback to an earlier revision
- [ ] The service is still running with `desired-count` ≥ 1

## Discussion

1. Your endpoint is an IP that changes when the task is replaced. Name three things an ALB
   would give you beyond a stable name.
2. Both containers are `essential`. When would you deliberately mark a sidecar
   non-essential?
3. Rollback was a pointer change because revisions are immutable. What else in your Day 1
   and Day 2 pipeline is *not* immutable, and what would it take to make it so?

---

**Footnote to Exercise 8.1:** ECR reports compressed layer sizes; `docker images` reports
the uncompressed on-disk size. The compressed number is what crosses the network on every
task start, which makes it the number that matters for scale-out latency.
