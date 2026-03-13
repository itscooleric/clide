#!/bin/bash
# debug-notify.sh — Test notification pipeline end-to-end
# Run from inside the clidef terminal

echo "=== Notify Debug ==="

# Kill any old notify processes
pkill -f notify.sh 2>/dev/null
sleep 1

echo ""
echo "1. Environment check:"
echo "   CLIDE_NTFY_URL=$CLIDE_NTFY_URL"
echo "   CLIDE_NTFY_TOPIC=${CLIDE_NTFY_TOPIC:-clide}"

echo ""
echo "2. Direct curl test:"
RESULT=$(curl -sf -X POST "${CLIDE_NTFY_URL}/${CLIDE_NTFY_TOPIC:-clide}" \
  -H "Title: Debug Test" \
  -d "Direct curl at $(date)" 2>&1)
echo "   curl exit code: $?"
echo "   Did you get a notification? (wait 5s)"
sleep 5

echo ""
echo "3. Testing notify.sh with bash -x:"
TMPFILE=$(mktemp /tmp/test-transcript-XXXX.txt)
echo "   transcript: $TMPFILE"

bash -x /usr/local/bin/notify.sh "$TMPFILE" debug-session claude > /tmp/notify-debug.log 2>&1 &
NPID=$!
echo "   notify PID: $NPID"
sleep 2

echo ""
echo "4. Triggering pattern match..."
echo "Allow once" >> "$TMPFILE"
sleep 3

echo ""
echo "5. Notify process status:"
if kill -0 $NPID 2>/dev/null; then
  echo "   Still running (good)"
else
  echo "   DEAD — exited early"
fi

echo ""
echo "6. Debug log (last 30 lines):"
tail -30 /tmp/notify-debug.log

echo ""
echo "7. Cleanup"
kill $NPID 2>/dev/null
rm -f "$TMPFILE"
echo "   Done"
