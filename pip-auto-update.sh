. ./.env

python_service_name_list=("portfolio-app" "finote-app" "shifree-app")

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
# 引数：$1（is_rollback, diff_text, error_pkg）
get_file_path() {
    local flag=$1
    local file_path

    if [ $flag = "is_rollback" ]; then
        file_path=${TMP_FILE_LIST[0]}
    elif [ $flag = "diff_text" ]; then
        file_path=${TMP_FILE_LIST[1]}
    else
        file_path=${TMP_FILE_LIST[2]}
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

# 各サービスごとのパッケージ更新の差分のテキストを生成する。
# rollbackした場合はrollbackとだけ出力する。
# 引数　$1:差分の文字列（スペース区切り）, $2:index
create_diff_text() {
    local diff_text=""
    local diff_list=$1
    local index=$2
    local diff
    local is_rollback=$(get_value_from_csv is_rollback $index 2)

    if [[ $is_rollback = 1 ]]; then
        diff_text="${diff_text}\`rollback\`\n"
    else
        if [[ -n "${diff_list}" ]]; then
            diff_text="${diff_text}\`\`\`"
            for diff in ${diff_list[@]}; do
                diff_text="${diff_text}${diff}\n"
            done

            diff_text="${diff_text}\`\`\`\n\n"
        fi
    fi

    echo $diff_text
}

# 差分、エラー情報を通知用のテキストとして1つにまとめる。
create_notification_text() {
    local text=""
    local index

    for index in "${!python_service_name_list[@]}"; do
        local err_pkg_info_text=$(get_value_from_csv error_pkg $index 2)
        local diff_text=$(get_value_from_csv diff_text $index 2)

        text="${text}*\`${python_service_name_list[index]}\`*\n"
        text="${text}${err_pkg_info_text}"
        text="${text}${diff_text}\n\n"
    done

    echo $text
}

# slack通知
send_notification() {
    local text=$1
    local channel=${channel:-'#auto-update'}
    local botname=${botname:-'pip-auto-update'}
    local icon_url=${icon_url:-'https://img.icons8.com/color/480/000000/python.png'}
    local message=`echo ${text}`
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
    local outdated_pkg
    local error_pkg_info_list=()

    # for index in "${!python_service_name_list[@]}"; do
    local docker_exec_command="docker exec ${python_service_name_list[index]}"

    # 現在のインストール状態を一時保存（通知・pip check時のロールバック用）
    local now_pkg_list=$(${docker_exec_command} pip list --format=freeze)

    ${docker_exec_command} pip install -U pip

    local outdated_pkg_list=$(${docker_exec_command} pip list --outdated --format=freeze | awk -F "==" '{print $1}')
    local outdated_pkg_list=(`echo $outdated_pkg_list`)

    for outdated_pkg in ${outdated_pkg_list[@]}; do
        local now_version=$(${docker_exec_command} pip list | grep $outdated_pkg | awk -F " " '{print $2}')
        local update_error=$(${docker_exec_command} pip install -U $outdated_pkg 2>&1 > /dev/null)

        # pip installでエラーが起きた場合はバージョンを戻す
        if [ -n "$update_error" ]; then
            ${docker_exec_command} pip install "${outdated_pkg}==${now_version}"

            local tmp_pkg_info="${outdated_pkg}==${now_version}--->ErrorDependency"
            error_pkg_info_list+=($tmp_pkg_info)
        fi
    done

    ${docker_exec_command} pip check
    status=$?

    # 依存関係が解消されない場合は全てを戻す
    if [ $status = 1 ]; then
        ${docker_exec_command} pip freeze | xargs pip uninstall -y
        for now_pkg in ${now_pkg_list[@]}; do
            ${docker_exec_command} pip install $now_pkg
        done
        write_csv is_rollback $index 1
        write_csv diff_text $index \n\`\`\`NODIFF\`\`\`\n
    else
        write_csv is_rollback $index 0
        local updated_pkg_list=$(${docker_exec_command} pip list --format=freeze)
        local diff=$(diff -u <(echo "${now_pkg_list[@]}") <(echo "${updated_pkg_list[@]}") | grep -E '(^-\w|^\+\w)')
        local tmp_diff=`create_diff_text "$diff" "$index"`

        if [ -z "$tmp_diff" ]; then
            write_csv diff_text $index \\n\`\`\`NODIFF\`\`\`\\n
        else
            write_csv diff_text $index $tmp_diff
        fi

        local error_pkg_info_text=""

        # TODO: 関数として切り出し
        if [ ${#error_pkg_info_list[@]} -ge 1 ]; then
            error_pkg_info_text="${error_pkg_info_text}\`\`\`"

            for error_pkg_info in ${error_pkg_info_list[@]}; do
                error_pkg_info_text="${error_pkg_info_text}${error_pkg_info}\n"
            done

            error_pkg_info_text="${error_pkg_info_text}\`\`\`\n"
        fi

        write_csv error_pkg $index $error_pkg_info_text
    fi

    update_requirements $index
    git_push $index
}

# dockerの再起動を行う
# 返り値：サービスごとのコマンド実行ステータス。サービスの順番と同様。（0:成功, 1:失敗）
restart_docker() {
    local docker_compose_file_path
    local pids=()
    local flag=()
    local pid

    for docker_compose_file_path in ${DOCKER_COMPOSE_FILE_PATH_LIST[@]}; do
        cd $docker_compose_file_path && docker-compose restart &
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
    local text="\n\n*\`docker restart status\`*\n\n"
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

update_requirements() {
    local index=$1
    local file_path="${REQUIREMENTS_FOLDER_PATH_LIST[index]}requirements.txt"

    docker exec ${python_service_name_list[index]} pip freeze > $file_path
}

git_push() {
    local index=$1
    local folder_path=${REQUIREMENTS_FOLDER_PATH_LIST[index]}
    local command_status

    cd "$folder_path" && git add "requirements.txt" && git commit -m "pip-auto-update"

    command_status=$?

    if [ $command_status -eq 0 ]; then
        git push
    else
        git checkout .
    fi
}

main() {
    local command=""
    local index

    init_tmp_files

    for index in "${!python_service_name_list[@]}"; do
        command="${command}update ${index}&"
    done

    eval $command
    wait

    send_notification $(create_notification_text)

    local restart_docker_statues=$(restart_docker)

    local docker_restart_status_text=$(create_docker_restart_status_text ${restart_docker_statues[@]})

    send_notification "$docker_restart_status_text"
}

main
