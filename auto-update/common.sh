. ../.env

# *******************************************
#                  コンテナ
# *******************************************
check_container() {
    local is_running_list=()
    local command=$1
    local service_names=(${@:2})

    for service_name in "${service_names[@]}"; do
        docker exec -i ${service_name} $command 1>/dev/null 2>/dev/null

        if [ $? -eq 0 ]; then
            is_running_list+=(0)
        else
            is_running_list+=(1)
        fi
    done

    echo ${is_running_list[@]}
}

restart_docker() {
    local docker_compose_file_paths=("$@")
    local docker_compose_file_path
    local pids=()
    local flag=()
    local pid

    for docker_compose_file_path in ${docker_compose_file_paths[@]}; do
        cd $docker_compose_file_path && /usr/local/bin/docker-compose down 1>/dev/null 2>/dev/null && /usr/local/bin/docker-compose build --no-cache 1>/dev/null 2>/dev/null  && /usr/local/bin/docker-compose up -d 1>/dev/null 2>/dev/null &
        # cd $docker_compose_file_path && /usr/local/bin/docker-compose down 1>/dev/null 2>/dev/null && /usr/local/bin/docker-compose up -d  1>/dev/null 2>/dev/null &
        pids+=($!)
    done

    for pid in ${pids[@]}; do
        wait $pid
        if [ $? -eq 0 ]; then
            flag+=(0)
        else
            flag+=(1)
        fi
    done

    echo ${flag[@]}
}



# *******************************************
#                  ファイル
# *******************************************
init_tmp_files() {
    local file_path
    for file_path in ${PIP_TMP_FILE_LIST[@]};do
        : > $file_path
    done
}

remove_tmp_files() {
    local file_path
    for file_path in ${PIP_TMP_FILE_LIST[@]};do
        rm -f $file_path
    done
}

write_csv() {
    local file_path=$(get_file_path $1)
    local index=$2
    local value=$3
    echo "$index,$value" >> $file_path
}

get_file_path() {
    local flag=$1
    local file_path

    if [ $flag = "is_rollback" ]; then
        file_path=${PIP_TMP_FILE_LIST[0]}
    elif [ $flag = "error_pkg" ]; then
        file_path=${PIP_TMP_FILE_LIST[1]}
    elif [ $flag = "git_push_submodule" ]; then
        file_path=${PIP_TMP_FILE_LIST[2]}
    elif [ $flag = "skip" ]; then
        file_path=${PIP_TMP_FILE_LIST[3]}
    fi

    echo $file_path
}

get_value_from_csv() {
    local flag=$1
    local file_path=$(get_file_path $flag)
    local index=$2
    local column_num=$3
    local value=$(cat $file_path | awk -F , '$1 == '$index' {print '\$$column_num'}')
    local status=$?

    if [ $status -eq 0 ]; then
        echo $value
    else
        echo ""
    fi
}

collect_text_from_csv() {
    local service_names=("$*")
    local text=""
    local index

    for index in "${!service_names[@]}"; do
        local is_rollback_text=$(get_value_from_csv is_rollback $index 2)
        local err_pkg_text=$(get_value_from_csv error_pkg $index 2)
        local git_push_submodule_text=$(get_value_from_csv git_push_submodule $index 2)
        local skip_text=$(get_value_from_csv skip $index 2)

        text="${text}*\`${service_names[index]}\`*\n"

        if [ $is_rollback_text -eq 1 ]; then
            text="${text}\`\`\`is_rollback\`\`\`\n"
        fi

        if [ -n "$err_pkg_text" ]; then
            text="${text}$err_pkg_text\n"
        fi

        if [ -n "$skip_text" ]; then
            text="${text}$skip_text\n"
        fi

        if [ -n "$git_push_submodule_text" ]; then
            text="${text}$git_push_submodule_text\n"
        fi

        text="${text}\n"
    done

    echo $text
}



# *******************************************
#                  GitHub
# *******************************************
# サブモジュール内部の更新
git_push_submodule() {
    local index=$1
    local folder_path=$2
    local module_name=$3
    local command_status

    rm -f $aggregate_folder_path.git/modules/$module_name/COMMIT_EDITMSG
    cd "$folder_path" && git add . && git commit -m "auto-update"
    local submodule_command_status=$?
    local aggregate_command_status=0
    
    local commit_link=$(get_commit_link $index $folder_path $module_name)

    if [ $submodule_command_status -ne 0 ]; then
        git checkout .
        write_csv "git_push_submodule" $index "\`\`\`【checkout】\n${commit_link}\`\`\`"
    else
        git push
        write_csv "git_push_submodule" $index "\`\`\`【pushed】\n${commit_link}\`\`\`"
    fi
}

get_commit_link() {
    local index=$1
    local folder_path=$2
    local repository_name=$3
    local latest_commit=$(cd ${folder_path} && git show -s --format=%H)

    echo "https://github.com/kentaiwami/$repository_name/commit/${latest_commit}"
}

git_push_aggregate() {
    local repository_names=("$@")

    cd $aggregate_folder_path

    for repository_name in ${repository_names[@]}; do
        git add ${repository_name}
    done

    git commit -m "auto-update" > /dev/null
    local latest_commit=$(git show -s --format=%H)

    git push

    echo $latest_commit
}



# *******************************************
#                  テキスト
# *******************************************
create_docker_restart_status_text() {
    local service_name=$1
    local statuses=(${@:2})
    local text="*\`docker restart status\`*\n\n"
    local index

    for index in ${!statuses[@]}; do
        local mark=""
        if [ ${statuses[index]} -eq 0 ]; then
            mark=":white_check_mark:"
        else
            mark=":x:"
        fi

        text="${text}${mark} *$service_name*\n\n"
    done

    echo $text
}

create_aggregate_result_text() {
    local commit_hash=$1
    local commit_link="https://github.com/kentaiwami/aggregate/commit/${commit_hash}"
    echo "\`\`\`【aggregate】\n$commit_link\`\`\`\n"
}



# *******************************************
#                  Slack
# *******************************************
send_notification() {
    local text=$1
    local tmp_botname=$2
    local tmp_icon_url=$3
    local channel=${channel:-'#auto-update'}
    local botname=${botname:-$tmp_botname}
    local icon_url=${icon_url:-$tmp_icon_url}
    local payload="payload={
        \"channel\": \"${channel}\",
        \"username\": \"${botname}\",
        \"icon_url\": \"${icon_url}\",
        \"text\": \"${text}\"
    }"

    curl -s -S -X POST -d "${payload}" ${SLACK_AUTO_UPDATE_URL} > /dev/null
}