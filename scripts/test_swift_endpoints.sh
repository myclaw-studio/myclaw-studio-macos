#!/bin/bash
# Swift Backend Endpoint Tests
# Usage: ./scripts/test_swift_endpoints.sh
# Requires: App running (port 8000 Swift — Python no longer needed)

set -euo pipefail

BASE="http://127.0.0.1:8000"
PASS=0
FAIL=0
ERRORS=""

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }
gray()  { echo -e "\033[0;90m$*\033[0m"; }

assert_status() {
    local desc="$1" method="$2" url="$3" expected="$4"
    shift 4
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$@" "$BASE$url")
    if [ "$status" = "$expected" ]; then
        green "  PASS  $desc ($method $url -> $status)"
        PASS=$((PASS + 1))
    else
        red "  FAIL  $desc ($method $url -> $status, expected $expected)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $desc: got $status, expected $expected"
    fi
}

assert_json_field() {
    local desc="$1" method="$2" url="$3" field="$4" expected="$5"
    shift 5
    local body
    body=$(curl -s -X "$method" "$@" "$BASE$url")
    local actual
    actual=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field','__MISSING__'))" 2>/dev/null || echo "__ERROR__")
    if [ "$actual" = "$expected" ]; then
        green "  PASS  $desc (.$field == $expected)"
        PASS=$((PASS + 1))
    else
        red "  FAIL  $desc (.$field == '$actual', expected '$expected')"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $desc: .$field='$actual', expected '$expected'"
    fi
}

assert_json_array_min() {
    local desc="$1" method="$2" url="$3" min_len="$4"
    shift 4
    local body
    body=$(curl -s -X "$method" "$@" "$BASE$url")
    local count
    count=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else -1)" 2>/dev/null || echo "-1")
    if [ "$count" -ge "$min_len" ]; then
        green "  PASS  $desc (array length=$count >= $min_len)"
        PASS=$((PASS + 1))
    else
        red "  FAIL  $desc (array length=$count, expected >= $min_len)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $desc: array length=$count, expected >= $min_len"
    fi
}

echo ""
echo "========================================="
echo "  Swift Backend Endpoint Tests"
echo "========================================="
echo ""

# ── Check servers are up ────────────────────────────────
echo "[Pre-check] Servers..."
assert_status "Swift server alive" GET "/health" 200
assert_json_field "Health status=ok" GET "/health" "status" "ok"

gray "  SKIP  Python backend removed (all Swift now)"
echo ""

# ── Phase 1: Agents CRUD ──────────────────────────────
echo "[Phase 1] Agents CRUD..."
assert_json_array_min "List agents (seed data)" GET "/agents" 1

# Create agent
AGENT_RESP=$(curl -s -X POST "$BASE/agents" \
    -H "Content-Type: application/json" \
    -d '{"name":"TestBot","icon":"🧪","description":"test agent","system_prompt":"you are a test","tools":[],"max_steps":5}')
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "" ]; then
    green "  PASS  Create agent (id=$AGENT_ID)"
    PASS=$((PASS + 1))
else
    red "  FAIL  Create agent (no id returned)"
    FAIL=$((FAIL + 1))
    AGENT_ID=""
fi

# Update agent
if [ -n "$AGENT_ID" ]; then
    assert_status "Update agent" PUT "/agents/$AGENT_ID" 200 \
        -H "Content-Type: application/json" \
        -d '{"name":"TestBot Updated","max_steps":8}'
fi

# Delete agent
if [ -n "$AGENT_ID" ]; then
    assert_status "Delete agent" DELETE "/agents/$AGENT_ID" 200
    assert_status "Delete agent 404" DELETE "/agents/nonexistent-id-xxx" 404
fi
echo ""

# ── Phase 1: Skills CRUD ─────────────────────────────
echo "[Phase 1] Skills CRUD..."
assert_json_array_min "List skills (zh)" GET "/skills?lang=zh" 1
assert_json_array_min "List skills (en)" GET "/skills?lang=en" 1

# Create skill
curl -s -X POST "$BASE/skills" \
    -H "Content-Type: application/json" \
    -d '{"id":"test-skill-001","name":"Test Skill","description":"for testing","icon":"🧪","system_prompt":"test","tools":[]}' > /dev/null
assert_status "Delete user skill" DELETE "/skills/test-skill-001" 200
assert_status "Delete builtin skill blocked" DELETE "/skills/algorithmic-art" 400
echo ""

# ── Phase 1: Projects CRUD ────────────────────────────
echo "[Phase 1] Projects CRUD..."
assert_json_array_min "List projects" GET "/projects" 1

# Create project
assert_status "Create project" POST "/projects/test-swift-proj" 200 \
    -H "Content-Type: application/json" \
    -d '{"description":"test project"}'
assert_json_array_min "List project files" GET "/projects/test-swift-proj/files" 1
assert_status "Project not found" GET "/projects/nonexistent-proj-xxx/files" 404

# Cleanup
rm -rf ~/.aichat/projects/test-swift-proj
echo ""

# ── Phase 2a: Watchlist ──────────────────────────────
echo "[Phase 2a] Watchlist..."
assert_json_array_min "List watchlist" GET "/watchlist" 1
assert_status "Get watchlist config" GET "/watchlist/config" 200
assert_json_field "Config has smtp_host" GET "/watchlist/config" "smtp_host" ""
assert_status "Get poll status" GET "/watchlist/poll/status" 200
assert_json_field "Poll status field" GET "/watchlist/poll/status" "poll_enabled" "False"
assert_status "Get watchlist logs (empty)" GET "/watchlist/seed_morning_news/logs" 200
assert_json_array_min "Watchlist logs array" GET "/watchlist/seed_morning_news/logs" 0

# Save config
assert_status "Save watchlist config" POST "/watchlist/config" 200 \
    -H "Content-Type: application/json" \
    -d '{"smtp_host":"smtp.example.com","smtp_port":465,"smtp_user":"user@example.com","smtp_pass":"test_placeholder","notify_email":"notify@example.com","enabled":false,"poll_enabled":false}'

# Verify password masking
MASKED=$(curl -s "$BASE/watchlist/config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('smtp_pass',''))")
if [ "$MASKED" = "••••••••" ]; then
    green "  PASS  Password masked in config response"
    PASS=$((PASS + 1))
else
    red "  FAIL  Password not masked (got: $MASKED)"
    FAIL=$((FAIL + 1))
fi

# Save with masked password (should preserve original)
assert_status "Save config with masked pass" POST "/watchlist/config" 200 \
    -H "Content-Type: application/json" \
    -d '{"smtp_host":"smtp.example.com","smtp_port":465,"smtp_user":"user@example.com","smtp_pass":"••••••••","notify_email":"notify@example.com","enabled":false,"poll_enabled":false}'

# Restore clean config
curl -s -X POST "$BASE/watchlist/config" \
    -H "Content-Type: application/json" \
    -d '{"smtp_host":"","smtp_port":465,"smtp_user":"","smtp_pass":"","notify_email":"","enabled":false,"poll_enabled":false}' > /dev/null
echo ""

# ── Phase 2a: Memory / Diary ─────────────────────────
echo "[Phase 2a] Memory & Diary..."
assert_status "Get diary" GET "/memory/diary" 200
assert_json_array_min "Diary is array" GET "/memory/diary" 0
echo ""

# ── Phase 2a: Skill Market ───────────────────────────
echo "[Phase 2a] Skill Market..."
assert_status "Skill market popular" GET "/skill-market?tab=popular&limit=5" 200
assert_json_array_min "Market returns skills" GET "/skill-market?tab=popular&limit=5" 1

# Install market skill
assert_status "Install market skill" POST "/skill-market/install" 200 \
    -H "Content-Type: application/json" \
    -d '{"slug":"test-market-skill","display_name":"Test Market Skill","summary":"test","downloads":0,"stars":0}'

# Verify installed flag
INSTALLED=$(curl -s "$BASE/skill-market?tab=popular&limit=100" | \
    python3 -c "import sys,json; skills=json.load(sys.stdin); matches=[s for s in skills if s.get('slug')=='test-market-skill']; print(matches[0]['installed'] if matches else 'NOT_FOUND')" 2>/dev/null || echo "ERROR")
# Clean up installed test skill
curl -s -X DELETE "$BASE/skills/test-market-skill" > /dev/null
echo ""

# ── Phase 2: Swift Tools ────────────────────────────
echo "[Phase 2] Swift Tools..."

# Tool names endpoint
TOOL_COUNT=$(curl -s "$BASE/tools/swift-names" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('names',[])))" 2>/dev/null)
if [ "$TOOL_COUNT" -ge 8 ]; then
    green "  PASS  Swift tool names ($TOOL_COUNT tools registered)"
    PASS=$((PASS + 1))
else
    red "  FAIL  Swift tool names (got $TOOL_COUNT, expected >= 8)"
    FAIL=$((FAIL + 1))
fi

# Tool definitions
assert_json_array_min "Tool definitions" GET "/tools/definitions" 8

# Execute file_manager
EXEC_RESULT=$(curl -s -X POST "$BASE/tools/execute" \
    -H "Content-Type: application/json" \
    -d '{"tool":"file_manager","params":{"action":"list","path":"~"}}' | \
    python3 -c "import sys,json; r=json.load(sys.stdin).get('result',''); print('OK' if r else 'EMPTY')")
if [ "$EXEC_RESULT" = "OK" ]; then
    green "  PASS  Execute file_manager (list ~)"
    PASS=$((PASS + 1))
else
    red "  FAIL  Execute file_manager (result=$EXEC_RESULT)"
    FAIL=$((FAIL + 1))
fi

# Execute run_code (shell)
SHELL_RESULT=$(curl -s -X POST "$BASE/tools/execute" \
    -H "Content-Type: application/json" \
    -d '{"tool":"run_code","params":{"code":"echo test42","language":"shell"}}' | \
    python3 -c "import sys,json; r=json.load(sys.stdin).get('result',''); print('OK' if 'test42' in r else 'FAIL')")
if [ "$SHELL_RESULT" = "OK" ]; then
    green "  PASS  Execute run_code (shell)"
    PASS=$((PASS + 1))
else
    red "  FAIL  Execute run_code (shell, result=$SHELL_RESULT)"
    FAIL=$((FAIL + 1))
fi

# Execute run_code (python)
PY_RESULT=$(curl -s -X POST "$BASE/tools/execute" \
    -H "Content-Type: application/json" \
    -d '{"tool":"run_code","params":{"code":"print(7*6)","language":"python"}}' | \
    python3 -c "import sys,json; r=json.load(sys.stdin).get('result',''); print('OK' if '42' in r else 'FAIL')")
if [ "$PY_RESULT" = "OK" ]; then
    green "  PASS  Execute run_code (python)"
    PASS=$((PASS + 1))
else
    red "  FAIL  Execute run_code (python, result=$PY_RESULT)"
    FAIL=$((FAIL + 1))
fi

# Execute system_info
assert_status "Execute system_info" POST "/tools/execute" 200 \
    -H "Content-Type: application/json" \
    -d '{"tool":"system_info","params":{"info_type":"system"}}'

# Execute unknown tool -> 404
assert_status "Execute unknown tool" POST "/tools/execute" 404 \
    -H "Content-Type: application/json" \
    -d '{"tool":"nonexistent_tool","params":{}}'

echo ""

# ── Phase 5a: Memory System ──────────────────────────
echo "[Phase 5a] Memory System..."
assert_status "GET /memory (list)" GET "/memory" 200
# Add a test memory
RESP=$(curl -s -X POST "$BASE/memory" -H "Content-Type: application/json" -d '{"text":"测试记忆条目","type":"fact","tier":"general"}')
MEM_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
if [ -n "$MEM_ID" ] && [ "$MEM_ID" != "None" ]; then
    green "  PASS  Add memory (id=$MEM_ID)"
    PASS=$((PASS+1))
else
    red "  FAIL  Add memory"
    FAIL=$((FAIL+1))
fi
# Search memory
assert_status "POST /memory/search" POST "/memory/search" 200 -d '{"query":"测试","mode":"search"}'
# Delete the test memory
if [ -n "$MEM_ID" ] && [ "$MEM_ID" != "None" ]; then
    assert_status "DELETE /memory/$MEM_ID" DELETE "/memory/$MEM_ID" 200
fi
# Deduplicate
assert_status "POST /memory/deduplicate" POST "/memory/deduplicate" 200
# Diary
assert_status "GET /memory/diary (swift)" GET "/memory/diary" 200
# Memory search tool (via tool execute)
RESP=$(curl -s -X POST "$BASE/tools/execute" -H "Content-Type: application/json" -d '{"tool":"memory_search","params":{"query":"测试","mode":"search"}}')
if echo "$RESP" | python3 -c "import sys,json; r=json.load(sys.stdin); assert 'result' in r" 2>/dev/null; then
    green "  PASS  Execute memory_search tool"
    PASS=$((PASS+1))
else
    red "  FAIL  Execute memory_search tool"
    FAIL=$((FAIL+1))
fi
echo ""

# ── Phase 6: All-Swift endpoints ────────────────────
echo "[Phase 6] All-Swift endpoints (no Python)..."
assert_status "GET /tools (swift)" GET "/tools" 200
assert_json_array_min "Tools list" GET "/tools" 5
assert_status "GET /mcp/presets (swift)" GET "/mcp/presets" 200
assert_json_array_min "MCP presets" GET "/mcp/presets" 10
assert_status "GET /mcp/servers (swift)" GET "/mcp/servers" 200

# MCP server install/remove (quick test with a non-existent server)
assert_status "POST /mcp/servers (install test)" POST "/mcp/servers" 400 \
    -H "Content-Type: application/json" \
    -d '{"name":"","command":[]}'

# Composio endpoints
assert_status "GET /composio/toolkits" GET "/composio/toolkits" 200

# Fallback 404
assert_status "Unknown route returns 404" GET "/nonexistent/route" 404
echo ""

# ── Summary ───────────────────────────────────────────
echo "========================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "  ALL $TOTAL TESTS PASSED"
else
    echo -e "  $(green "$PASS passed"), $(red "$FAIL failed") / $TOTAL total"
    echo -e "\nFailures:$ERRORS"
fi
echo "========================================="
echo ""

exit $FAIL
