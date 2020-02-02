send_notification() {
    local text=$1
    local botname=${botname:-$2}
    local icon_url=${icon_url:-$3}
    local channel=${channel:-$4}
    local url=$5
    local payload="payload={
        \"channel\": \"${channel}\",
        \"username\": \"${botname}\",
        \"icon_url\": \"${icon_url}\",
        \"text\": \"${text}\"
    }"

    curl -s -S -X POST -d "${payload}" ${url} > /dev/null
}
