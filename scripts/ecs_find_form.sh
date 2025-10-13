#!/bin/bash

# Get environment
ACCOUNT=$(aws sts get-caller-identity | jq -r ".Account")
case $ACCOUNT in
960*) ENV="test" ;;
012*) ENV="dev" ;;
378*) ENV="uat" ;;
233*) ENV="prod" ;;
esac

echo "Environment: $ENV"
echo

# Find the cluster
echo "Finding ECS cluster..."
CLUSTER=$(aws ecs list-clusters --query "clusterArns[?contains(@, 'pre-award-$ENV')]" --output text | head -1)

if [ -z "$CLUSTER" ]; then
  echo "No cluster found"
  exit 1
fi

echo "Cluster: $CLUSTER"
echo

# Find the Form Runner service
echo "Finding Form Runner service..."
SERVICE_ARN=$(aws ecs list-services --cluster "$CLUSTER" --query "serviceArns[?contains(@, 'form-runner-adapter')]" --output text)

if [ -z "$SERVICE_ARN" ]; then
  echo "No Form Runner service found"
  exit 1
fi

SERVICE_NAME=$(echo "$SERVICE_ARN" | awk -F'/' '{print $NF}')
echo "Service: $SERVICE_NAME"

# Find a running task
echo "Finding running task..."
TASK_ARN=$(aws ecs list-tasks \
  --cluster "$CLUSTER" \
  --service-name "$SERVICE_NAME" \
  --desired-status RUNNING \
  --query 'taskArns[0]' \
  --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" == "None" ]; then
  echo "No running tasks found"
  exit 1
fi

TASK_ID=$(echo $TASK_ARN | cut -d'/' -f3)
echo "Task ID: $TASK_ID"
echo

# Check if exec is enabled
EXEC_ENABLED=$(aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks $TASK_ARN \
  --query 'tasks[0].enableExecuteCommand' \
  --output text)

if [ "$EXEC_ENABLED" != "True" ]; then
  echo "⚠️  ECS Exec is not enabled"
  SERVICE_ARN=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASK_ARN --query 'tasks[0].group' --output text | sed 's/service://')
  echo "Enable it with:"
  echo "  aws ecs update-service --cluster $CLUSTER --service $SERVICE_ARN --enable-execute-command --force-new-deployment"
  exit 1
fi

echo "✓ ECS Exec is enabled"
echo

# Define the Node.js script to be run inside the container
read -r -d '' NODE_SCRIPT <<'EOF'
const Redis = require('ioredis');
const crypto = require('crypto');
const REFERENCE_PAGES = [{ path: '/proposal' }, { path: '/are-you-applying-for-pillar-1---foundations-funding' }];

let redisUri = null;
for (const key in process.env) {
  if (process.env[key] && typeof process.env[key] === 'string' && process.env[key].includes('.cache.amazonaws.com')) {
    redisUri = process.env[key];
    console.log(`Found Redis URI in env var ${key}: ${redisUri}`);
    break;
  }
}

if (!redisUri) {
  console.error('Could not find Redis URI in environment variables.');
  process.exit(1);
}

const redis = new Redis(redisUri, { tls: { rejectUnauthorized: false } });

(async () => {
  console.log('Connecting and searching Redis...');
  const keys = await redis.keys('forms:cache:*');
  console.log(`Found ${keys.length} total forms.\n`);
  const resultsByHash = {};

  for (const key of keys) {
    const data = await redis.get(key);
    if (data) {
      try {
        const formData = JSON.parse(data);
        const config = formData.configuration || formData;
        const pages = config.pages || [];
        if (pages.length >= 2 && pages[0].path === REFERENCE_PAGES[0].path && pages[1].path === REFERENCE_PAGES[1].path) {
          const formId = key.replace('forms:cache:', '');
          const hash = crypto.createHash('sha256').update(data).digest('hex');
          const size = data.length;

          if (!resultsByHash[hash]) {
            resultsByHash[hash] = { size, pages: pages.length, forms: [] };
          }
          resultsByHash[hash].forms.push(formId);
        }
      } catch (e) {
        // Ignore data that isn't valid JSON
      }
    }
  }

  console.log('--- Analysis of Matching Forms ---');
  Object.keys(resultsByHash).forEach(hash => {
    const group = resultsByHash[hash];
    console.log(`\nGROUP HASH: ${hash.substring(0, 12)}...`);
    console.log(`  Forms in group: ${group.forms.length}`);
    console.log(`  Page count: ${group.pages}`);
    console.log(`  Size (bytes): ${group.size}`);
    group.forms.forEach(formId => {
      console.log(`    - https://form-designer.access-funding.test.communities.gov.uk/app/designer/${formId}`);
    });
  });

  redis.disconnect();
})().catch(err => {
  console.error(err);
  redis.disconnect();
});
EOF

# Base64 encode the script to avoid any shell interpretation issues
ENCODED_SCRIPT=$(echo "$NODE_SCRIPT" | base64 -w 0)

echo "Running Redis search..."
echo

# Execute the command by decoding the script inside the container and piping to node
aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$TASK_ARN" \
  --container fsd-form-runner-adapter \
  --interactive \
  --command "/bin/sh -c \"cd /usr/src/app/digital-form-builder-adapter && echo '$ENCODED_SCRIPT' | base64 -d | node\""