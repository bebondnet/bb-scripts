#!/usr/bin/env bash
# bebond-opencode-refresh — dynamically update OpenCode model from BB Gateway
# BEB-636: Fetches live models, applies priority order, writes config
# Run daily via cron or on demand with --models flag
set -euo pipefail

CONFIG="$HOME/.config/opencode/opencode.json"
GATEWAY="https://gateway.bebond.net/v1/models"

# Priority order: first available wins
PRIORITY_ORDER=(
  "z-ai/glm-5.1"
  "z-ai/glm-5"
  "z-ai/glm-4.7"
  "z-ai/glm-4.7-flash"
)

SMALL_PRIORITY_ORDER=(
  "z-ai/glm-4.7-flash"
  "z-ai/glm-5-turbo"
  "z-ai/glm-4.5-air:free"
)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ ! -f "$CONFIG" ]]; then
  echo -e "${RED}Error: OpenCode config not found at $CONFIG${NC}"
  echo "Run bebond-opencode-setup first."
  exit 1
fi

# Extract BB key from config — prefer openrouter provider, fallback to env
BB_KEY=$(jq -r '.provider.openrouter.options.apiKey // ""' "$CONFIG" 2>/dev/null || true)
if [[ "$BB_KEY" == '{env:BB_API_KEY}' || -z "$BB_KEY" ]]; then
  BB_KEY="${BB_API_KEY:-}"
fi

if [[ -z "$BB_KEY" ]]; then
  echo -e "${RED}Error: No BB API key found. Set BB_API_KEY env var or configure provider.openrouter.options.apiKey${NC}"
  exit 1
fi

# Fetch model list from gateway
echo "Fetching models from $GATEWAY ..."
RESP=$(curl -sf -m 15 -H "Authorization: Bearer $BB_KEY" "$GATEWAY" 2>/dev/null) || {
  echo -e "${RED}Error: Failed to fetch models from gateway${NC}"
  exit 1
}

# Extract available model IDs
AVAILABLE_IDS=$(echo "$RESP" | jq -r '.data[].id // .models[].id // empty' 2>/dev/null | sort -u)

if [[ -z "$AVAILABLE_IDS" ]]; then
  echo -e "${RED}Error: No models returned from gateway${NC}"
  exit 1
fi

MODEL_COUNT=$(echo "$AVAILABLE_IDS" | wc -l)
echo "  $MODEL_COUNT models available"

# Find best model by priority
BEST_MODEL=""
for candidate in "${PRIORITY_ORDER[@]}"; do
  if echo "$AVAILABLE_IDS" | grep -qxF "$candidate"; then
    BEST_MODEL="$candidate"
    break
  fi
done

if [[ -z "$BEST_MODEL" ]]; then
  echo -e "${YELLOW}Warning: No preferred model found. Falling back to first available z-ai model.${NC}"
  BEST_MODEL=$(echo "$AVAILABLE_IDS" | grep 'z-ai/' | head -1 || true)
fi

if [[ -z "$BEST_MODEL" ]]; then
  echo -e "${RED}Error: No z-ai models available from gateway${NC}"
  exit 1
fi

# Find best small model by priority
BEST_SMALL=""
for candidate in "${SMALL_PRIORITY_ORDER[@]}"; do
  if echo "$AVAILABLE_IDS" | grep -qxF "$candidate"; then
    BEST_SMALL="$candidate"
    break
  fi
done

if [[ -z "$BEST_SMALL" ]]; then
  BEST_SMALL="$BEST_MODEL"
fi

# Determine provider prefix from current model in config
CURRENT_MODEL=$(jq -r '.model' "$CONFIG")
PROVIDER_KEY=$(echo "$CURRENT_MODEL" | cut -d'/' -f1)
if [[ -z "$PROVIDER_KEY" || "$PROVIDER_KEY" == "$CURRENT_MODEL" ]]; then
  PROVIDER_KEY="openrouter"
fi

# Prefix models with provider (e.g. "openrouter/z-ai/glm-5.1")
FULL_MODEL="${PROVIDER_KEY}/${BEST_MODEL}"
FULL_SMALL="${PROVIDER_KEY}/${BEST_SMALL}"

# Read current small model
CURRENT_SMALL=$(jq -r '.small_model' "$CONFIG")

echo "  Current: model=$CURRENT_MODEL  small=$CURRENT_SMALL"
echo "  Best:    model=$FULL_MODEL  small=$FULL_SMALL"

if [[ "$CURRENT_MODEL" == "$FULL_MODEL" && "$CURRENT_SMALL" == "$FULL_SMALL" ]]; then
  echo -e "${GREEN}Config already up to date.${NC}"
  exit 0
fi

# Update config atomically
TMP=$(mktemp)
jq --arg model "$FULL_MODEL" \
   --arg small "$FULL_SMALL" \
   '.model = $model | .small_model = $small' \
   "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

echo -e "${GREEN}OpenCode model updated to $FULL_MODEL${NC}"
echo -e "${GREEN}Small model updated to $FULL_SMALL${NC}"
