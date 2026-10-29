trap '' TERM
IFS= read -r request || exit
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"stubborn","version":"1"}}}'
while IFS= read -r request; do :; done
while :; do :; done
