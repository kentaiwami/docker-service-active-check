. ./.env
. ./send_slack.sh

docker_service_names=("sumolog" "portfolio" "portfolio-redirect" "phpmyadmin" "letsencrypt" "proxy")
health_check_endpoint_service_names=(`echo ${docker_service_names[@]} | awk '{print $1}{print $2}{print $3}{print $4}{print $5}{print $6}'`)
ok_list=()
ng_list=()
cause_list=()

run_docker_process_command() {
    local service_name=$1
    local result_docker_process

    if [ $service_name = "portfolio" ]; then
        result_docker_process=$(docker ps -f "name=${service_name}" -f "status=running" --format "{{.Names}}\t{{.Status}}" | grep -v portfolio-redirect)
    else
        result_docker_process=$(docker ps -f "name=${service_name}" -f "status=running" --format "{{.Names}}\t{{.Status}}")
    fi

    echo "$result_docker_process"
}

check_docker_container() {
    local index
    local cause_docker_text="docker-process-is-down"

    for index in "${!docker_service_names[@]}"; do
        local service_name=${docker_service_names[$index]}
        local result_docker_process=`run_docker_process_command ${service_name}`
        local running_service_count=$(echo "$result_docker_process" | wc -l)

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
}

check_http_status() {
    ok_list=()
    ng_list=()
    cause_list=()
    local cause_http_status_text="http status is "

    for index in "${!health_check_endpoint_service_names[@]}"; do
        local http_status=(`curl -LI ${HEALTH_CHECK_URL[index]} -o /dev/null -w '%{http_code}\n' -s`)

        if [ $http_status -eq 200 ]; then
            ok_list+=(${health_check_endpoint_service_names[index]})
        else
            ng_list+=(${health_check_endpoint_service_names[index]})
            cause_list+=("$cause_http_status_text $http_status")
        fi
    done
}

create_text() {
    local text=""

    for ok_service_name in ${ok_list[@]}; do
        text="${text}:white_check_mark: *${ok_service_name}* \n\n"
    done

    for index in "${!ng_list[@]}"; do
        text="${text}:x: *${ng_list[$index]}* ${cause_list[$index]} \n\n"
    done

    echo "$text"
}

main() {
    # docker生存確認
    check_docker_container
    local docker_container_status_text=$(create_text)

    # http status確認
    check_http_status
    local http_status_text=$(create_text)

    send_notification "*\`docker container status\`*\n$docker_container_status_text\n*\`http status\`*\n$http_status_text" "health-check" "https://img.icons8.com/flat_round/64/000000/hearts.png" "#health-check" "$SLACK_HEALTH_CHECK_URL"
}

main
