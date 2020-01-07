. ./.env

service_name_list=("sumolog" "shifree" "portfolio" "portfolio-redirect" "finote" "phpmyadmin" "letsencrypt" "proxy")
ok_list=()
ng_list=()
cause_list=()
cause_docker_text="docker-process-is-down"

send_notification() {
    text=""

    for ok_service_name in ${ok_list[@]}; do
        text="${text}:white_check_mark: *${ok_service_name}* \n\n"
    done

    for index in "${!ng_list[@]}"; do
        text="${text}:x: *${ng_list[$index]}* ${cause_list[$index]} \n\n"
    done

    channel=${channel:-'#helth-check'}
    botname=${botname:-'helth-check'}
    emoji=${emoji:-':heartpulse:'}
    message=`echo ${text}`
    payload="payload={
        \"channel\": \"${channel}\",
        \"username\": \"${botname}\",
        \"icon_emoji\": \"${emoji}\",
        \"text\": \"${message}\"
    }"

    curl -s -S -X POST -d "${payload}" ${SLACK_NOTIFICATION_URL} > /dev/null
}

run_docker_process_command() {
    service_name=$1

    if [ $service_name = "portfolio" ]; then
        result_docker_process=$(docker ps -f "name=${service_name}" -f "status=running" --format "{{.Names}}\t{{.Status}}" | grep -v portfolio-redirect)
    else
        result_docker_process=$(docker ps -f "name=${service_name}" -f "status=running" --format "{{.Names}}\t{{.Status}}")
    fi

    echo "$result_docker_process"
}

for index in "${!service_name_list[@]}"; do
    service_name=${service_name_list[$index]}
    result_docker_process=`run_docker_process_command ${service_name}`
    running_service_count=$(echo "$result_docker_process" | wc -l)

    # docker psの結果が空文字だったらng確定
    if [ -z "$result_docker_process" ]; then
        ng_list+=($service_name)
        cause_list+=($cause_docker_text)
    else
        # 稼働中のサービスの個数が一致していなければng
        if [[ $running_service_count = ${ACTIVE_SERVICE_COUNT_LIST[$index]} ]]; then
            ok_list+=($service_name)
        else
            ng_list+=($service_name)
            cause_list+=($cause_docker_text)
        fi
    fi
done

send_notification
