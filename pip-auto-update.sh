. ./.env

python_service_name_list=("portfolio-app" "finote-app" "shifree-app")
script_path=$(cd $(dirname $0); pwd)

# 並列処理の結果を保存する一時ファイルを初期化する
init_tmp_files() {
    local file_path
    for file_path in ${TMP_FILE_LIST[@]};do
        : > $file_path
   done
}

# 一時ファイルの削除
remove_tmp_files() {
    local file_path
    for file_path in ${TMP_FILE_LIST[@]};do
        rm -f $file_path
    done
}

# 第一引数のフラグをもとに一時ファイルのパスを取得する
# 引数：$1（is_rollback, error_pkg, git）
get_file_path() {
    local flag=$1
    local file_path

    if [ $flag = "is_rollback" ]; then
        file_path=${TMP_FILE_LIST[0]}
    elif [ $flag = "error_pkg" ]; then
        file_path=${TMP_FILE_LIST[1]}
    elif [ $flag = "git_push" ]; then
        file_path=${TMP_FILE_LIST[2]}
    elif [ $flag = "skip" ]; then
        file_path=${TMP_FILE_LIST[3]}
    fi

    echo $file_path
}

# 指定された値を指定したファイルに書き込む
# 引数　$1:flag, $2:index, $3:value
write_csv() {
    local file_path=$(get_file_path $1)
    local index=$2
    local value=$3
    echo "$index,$value" >> $file_path
}

# 指定したファイル、index,カラム番号の値を取得する
# 引数　$1:flag, $2:index, $3:column_number（0:行, 1:1番目, 2:2番目）
get_value_from_csv() {
    local file_path=$(get_file_path $1)
    local index=$2
    local column_num=$3
    cat $file_path | awk -F , '$1 == '$index' {print '\$$column_num'}'
}

# スキップ、git、エラーパッケージ情報をcsvからまとめる
aggregate_text_from_csv() {
    local text=""
    local index

    for index in "${!python_service_name_list[@]}"; do
        local is_rollback_text=$(get_value_from_csv is_rollback $index 2)
        local err_pkg_text=$(get_value_from_csv error_pkg $index 2)
        local git_push_text=$(get_value_from_csv git_push $index 2)
        local skip_text=$(get_value_from_csv skip $index 2)

        text="${text}*\`${python_service_name_list[index]}\`*\n"

        if [ $is_rollback_text -eq 1 ]; then
            text="${text}\`\`\`is_rollback\`\`\`\n"
        fi

        if [ -n "$err_pkg_text" ]; then
            text="${text}$err_pkg_text\n"
        fi

        if [ -n "$skip_text" ]; then
            text="${text}$skip_text\n"
        fi

        if [ -n "$git_push_text" ]; then
            text="${text}$git_push_text\n"
        fi

        text="${text}\n"
    done

    echo $text
}

# slack通知
send_notification() {
    local text=$1
    local channel=${channel:-'#auto-update'}
    local botname=${botname:-'pip-auto-update'}
    local icon_url=${icon_url:-'https://img.icons8.com/color/480/000000/python.png'}
    local payload="payload={
        \"channel\": \"${channel}\",
        \"username\": \"${botname}\",
        \"icon_url\": \"${icon_url}\",
        \"text\": \"${text}\"
    }"

    curl -s -S -X POST -d "${payload}" ${SLACK_AUTO_UPDATE_URL} > /dev/null
}

update() {
    local index=$1
    local is_skip=$2
    local outdated_pkg
    local error_pkg_info_list=()
    local docker_exec_command="docker exec -i ${python_service_name_list[index]} bash -c"
    local python_module_command="python -m"

    # docker execが失敗するサービスは以降の処理を実施しない
    if [ $is_skip -eq 1 ]; then
        write_csv "error_pkg" $index ""
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${python_service_name_list[index]}* is Skip\n"
        exit
    fi

    write_csv "skip" $index ""

    ${docker_exec_command} "${python_module_command} pip install -U pip"
    local outdated_pkg_list=$(${docker_exec_command} "${python_module_command} pip list --outdated --format=freeze" | awk -F "==" '{print $1}')
    local outdated_pkg_list=(`echo $outdated_pkg_list`)

    for outdated_pkg in ${outdated_pkg_list[@]}; do
        local now_version=$(${docker_exec_command} "${python_module_command} pip list" | grep $outdated_pkg | awk -F " " '{print $2}')
        local update_error=$(${docker_exec_command} "${python_module_command} pip install -U $outdated_pkg" 2>&1 > /dev/null)

        # pip installでエラーが起きた場合はバージョンを戻す
        if [ -n "$update_error" ]; then
            ${docker_exec_command} "${python_module_command} pip install "${outdated_pkg}==${now_version}""

            local tmp_pkg_info="${outdated_pkg}==${now_version}"
            error_pkg_info_list+=($tmp_pkg_info)
        fi
    done

    ${docker_exec_command} "${python_module_command} pip check"
    status=$?

    # 依存関係が解消されない場合はrequirements.txtを更新せずに再起動で元に戻す
    if [ $status = 1 ]; then
        write_csv "is_rollback" $index 1
    else
        write_csv "is_rollback" $index 0

        local error_pkg_info_text=$(create_error_pkg_text ${error_pkg_info_list[@]})
        write_csv "error_pkg" $index $error_pkg_info_text

        update_requirements $index
        git_push $index
    fi
}

# dockerの再起動を行う
# 返り値：サービスごとのコマンド実行ステータス。サービスの順番と同様。（0:成功, 1:失敗）
restart_docker() {
    local docker_compose_file_path
    local pids=()
    local flag=()
    local pid

    for docker_compose_file_path in ${DOCKER_COMPOSE_FILE_PATH_LIST[@]}; do
        cd $docker_compose_file_path && docker-compose down && docker-compose build --no-cache && docker-compose up -d &
        # cd $docker_compose_file_path && docker-compose down && docker-compose up -d &
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

# docker再起動の結果をもとに、通知用のテキストを生成する。
# 返り値：生成したテキスト
create_docker_restart_status_text() {
    local statuses=("$@")
    local text="*\`docker restart status\`*\n\n"
    local index

    for index in ${!statuses[@]}; do
        local mark=""
        if [ ${statuses[index]} -eq 0 ]; then
            mark=":white_check_mark:"
        else
            mark=":x:"
        fi

        text="${text}${mark} *${python_service_name_list[index]}*\n\n"
    done

    echo $text
}

create_error_pkg_text() {
    local error_pkg_info_list=("$@")
    local error_pkg_info_text=""

    if [ ${#error_pkg_info_list[@]} -ge 1 ]; then
        error_pkg_info_text="${error_pkg_info_text}\`\`\`【ErrorDependency】\n"

        for error_pkg_info in ${error_pkg_info_list[@]}; do
            error_pkg_info_text="${error_pkg_info_text}・${error_pkg_info}\n"
        done

        error_pkg_info_text="${error_pkg_info_text}\`\`\`"
    fi

    echo $error_pkg_info_text
}

update_requirements() {
    local index=$1
    local file_path="${REQUIREMENTS_FOLDER_PATH_LIST[index]}requirements.txt"

    docker exec -i ${python_service_name_list[index]} bash -c "python -m pip freeze" > $file_path
}

get_commit_link() {
    local index=$1
    local folder_path=${REQUIREMENTS_FOLDER_PATH_LIST[index]}
    local latest_commit=$(cd ${folder_path} && git show -s --format=%H)

    echo "https://github.com/kentaiwami/${REPOSITORY_NAME_LIST[index]}/commit/${latest_commit}"
}

git_push() {
    local index=$1
    local folder_path=${REQUIREMENTS_FOLDER_PATH_LIST[index]}
    local command_status

    cd "$folder_path" && git add "requirements.txt" && git commit -m "pip-auto-update"

    command_status=$?

    local commit_link=$(get_commit_link $index)

    # git commitをするためにcdしているため、元に戻す
    cd "$script_path"

    if [ $command_status -eq 0 ]; then
        git push
        write_csv "git_push" $index "\`\`\`【pushed】\n${commit_link}\`\`\`"
    else
        git checkout .
        write_csv "git_push" $index "\`\`\`checkout\n${commit_link}\`\`\`"
    fi
}

check_container() {
    local is_running_list=()

    for python_service_name in "${python_service_name_list[@]}"; do
        docker exec -i ${python_service_name} bash -c "python -m pip freeze > /dev/null"

        if [ $? -eq 0 ]; then
            is_running_list+=(0)
        else
            is_running_list+=(1)
        fi
    done

    echo ${is_running_list[@]}
}

main() {
    local result_check_container=$(check_container)
    result_check_container=(`echo $result_check_container`)

    local command=""
    local index

    init_tmp_files

    for index in "${!python_service_name_list[@]}"; do
        command="${command}update ${index} ${result_check_container[index]} & "
    done

    eval $command
    wait

    local cut_count=$((${#python_service_name_list[@]}+${#python_service_name_list[@]}-1))
    local tmp_restart_docker_statues=$(restart_docker)
    local restart_docker_statues=$(echo ${tmp_restart_docker_statues} | rev | cut -c 1-${cut_count} | rev)
    local docker_restart_status_text=$(create_docker_restart_status_text ${restart_docker_statues[@]})
    local updated_text=$(aggregate_text_from_csv)

    send_notification "$updated_text$docker_restart_status_text"

    remove_tmp_files
}

main
