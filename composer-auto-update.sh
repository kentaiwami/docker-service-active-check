#!/bin/bash

. ./.env

composer_service_name_list=("sumolog-app")

check_container() {
    local is_running_list=()

    for composer_service_name in "${composer_service_name_list[@]}"; do
        docker exec -i ${composer_service_name} composer show -i 1>/dev/null 2>/dev/null

        if [ $? -eq 0 ]; then
            is_running_list+=(0)
        else
            is_running_list+=(1)
        fi
    done

    echo ${is_running_list[@]}
}

# 並列処理の結果を保存する一時ファイルを初期化する
init_tmp_files() {
    local file_path
    for file_path in ${COMPOSER_TMP_FILE_LIST[@]};do
        : > $file_path
    done
}

update() {
    local index=$1
    local is_skip=$2
    local docker_exec_command="docker exec -i ${composer_service_name_list[index]}"

    # docker execが失敗するサービスは以降の処理を実施しない
    if [ $is_skip -eq 1 ]; then
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${composer_service_name_list[index]}* is Skip\n"
        exit
    fi

    write_csv "skip" $index ""

    sudo /usr/local/bin/composer self-update --stable

    cd ${COMPOSER_JSON_FOLDER_PATH_LIST} && composer update --dry-run

    dry_run_command_status=$?

    echo $dry_run_command_status

    if [ $dry_run_command_status -eq 0 ]; then
        composer clear-cache
        composer update
        update_command_status=$?

        if [ $update_command_status -eq 0 ];then
            git_push_submodule $index
            write_csv "is_rollback" $index 0
        else
            write_csv "skip" $index "\n:x: *${composer_service_name_list[index]}* is skip. Composer update error.\n"
        fi
    else
        write_csv "skip" $index "\n:x: *${composer_service_name_list[index]}* is skip. Composer update error.\n"
    fi
}

get_commit_link() {
    local index=$1
    local folder_path=${COMPOSER_DOCKER_COMPOSE_FILE_PATH_LIST[index]}
    local latest_commit=$(cd ${folder_path} && git show -s --format=%H)

    echo "https://github.com/kentaiwami/${COMPOSER_REPOSITORY_NAME_LIST[index]}/commit/${latest_commit}"
}

# サブモジュール内部の更新
git_push_submodule() {
    local index=$1
    local folder_path=${COMPOSER_JSON_FOLDER_PATH_LIST[index]}
    local command_status

    rm -f $aggregate_folder_path.git/modules/${COMPOSER_REPOSITORY_NAME_LIST[index]}/COMMIT_EDITMSG
    cd "$folder_path" && git add . && git commit -m "composer-auto-update"
    local submodule_command_status=$?
    local aggregate_command_status=0
    
    local commit_link=$(get_commit_link $index)

    if [ $submodule_command_status -ne 0 ]; then
        git checkout .
        write_csv "git_push_submodule" $index "\`\`\`【checkout】\n${commit_link}\`\`\`"
    else
        git push
        write_csv "git_push_submodule" $index "\`\`\`【pushed】\n${commit_link}\`\`\`"
    fi
}

git_push_aggregate() {
    cd $aggregate_folder_path

    for repository_name in ${COMPOSER_REPOSITORY_NAME_LIST[@]}; do
        git add ${repository_name}
    done

    git commit -m "composer-auto-update" > /dev/null
    local latest_commit=$(git show -s --format=%H)

    git push

    echo $latest_commit
}

create_aggregate_result_text() {
    local commit_hash=$1
    local commit_link="https://github.com/kentaiwami/aggregate/commit/${commit_hash}"
    echo "\`\`\`【aggregate】\n$commit_link\`\`\`\n"
}

# dockerの再起動を行う
# 返り値：サービスごとのコマンド実行ステータス。サービスの順番と同様。（0:成功, 1:失敗）
restart_docker() {
    local docker_compose_file_path
    local pids=()
    local flag=()
    local pid

    for docker_compose_file_path in ${COMPOSER_DOCKER_COMPOSE_FILE_PATH_LIST[@]}; do
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

        text="${text}${mark} *${composer_service_name_list[index]}*\n\n"
    done

    echo $text
}

# 指定したファイル、index,カラム番号の値を取得する
# 引数　$1:flag, $2:index, $3:column_number（0:行, 1:1番目, 2:2番目）
get_value_from_csv() {
    local file_path=$(get_file_path $1)
    local index=$2
    local column_num=$3
    cat $file_path | awk -F , '$1 == '$index' {print '\$$column_num'}'
}

# 一時ファイルの削除
remove_tmp_files() {
    local file_path
    for file_path in ${COMPOSER_TMP_FILE_LIST[@]};do
        rm -f $file_path
    done
}

# 第一引数のフラグをもとに一時ファイルのパスを取得する
# 引数：$1（is_rollback, error_pkg, git）
get_file_path() {
    local flag=$1
    local file_path

    if [ $flag = "is_rollback" ]; then
        file_path=${COMPOSER_TMP_FILE_LIST[0]}
    elif [ $flag = "git_push_submodule" ]; then
        file_path=${COMPOSER_TMP_FILE_LIST[1]}
    elif [ $flag = "skip" ]; then
        file_path=${COMPOSER_TMP_FILE_LIST[2]}
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

# 情報をcsvからまとめる
collect_text_from_csv() {
    local text=""
    local index

    for index in "${!composer_service_name_list[@]}"; do
        local is_rollback_text=$(get_value_from_csv is_rollback $index 2)
        local git_push_submodule_text=$(get_value_from_csv git_push_submodule $index 2)
        local skip_text=$(get_value_from_csv skip $index 2)

        text="${text}*\`${composer_service_name_list[index]}\`*\n"

        if [ $is_rollback_text -eq 1 ]; then
            text="${text}\`\`\`is_rollback\`\`\`\n"
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

# slack通知
send_notification() {
    local text=$1
    local channel=${channel:-'#auto-update'}
    local botname=${botname:-'composer-auto-update'}
    local icon_url=${icon_url:-'https://getcomposer.org/img/logo-composer-transparent.png'}
    local payload="payload={
        \"channel\": \"${channel}\",
        \"username\": \"${botname}\",
        \"icon_url\": \"${icon_url}\",
        \"text\": \"${text}\"
    }"

    curl -s -S -X POST -d "${payload}" ${SLACK_AUTO_UPDATE_URL} > /dev/null
}

main() {
    # dockerの生存確認
    local result_check_container=$(check_container)
    result_check_container=(`echo $result_check_container`)

    local command=""
    local index

    init_tmp_files

    for index in "${!composer_service_name_list[@]}"; do
        command="${command}update ${index} ${result_check_container[index]} & "
    done

    eval $command
    wait

    # # aggregate関連
    local git_push_aggregate_result=$(git_push_aggregate)
    local git_push_aggregate_result_text=$(create_aggregate_result_text $git_push_aggregate_result)

    # # docker restart関連
    local restart_docker_statues=$(restart_docker)
    local docker_restart_status_text=$(create_docker_restart_status_text ${restart_docker_statues[@]})

    local updated_text=$(collect_text_from_csv)

    send_notification "$updated_text$git_push_aggregate_result_text$docker_restart_status_text"

    remove_tmp_files
}

main
