. ./.env

# 他にグローバル変数として下記のものが存在する。
# 各サービスごとのパッケージのインストールエラーが発生した場合に、該当パッケージ名とバージョンの文字列を保存する配列
# 変数名：{サービス名(ハイフンをアンダースコアへ変換)}_error_pkg_list。例）portfolio-appなら変数名はportfolio_app_error_pkg_list

# python_service_name_list=("portfolio-app" "finote-app" "shifree-app")
python_service_name_list=("portfolio-app" "finote-app")
is_rollback_list=()
diff_text_list=()

# 各サービスごとのパッケージ更新の差分のテキストを生成する。
# rollbackした場合はrollbackとだけ出力する。
create_diff_text() {
    local diff_text=""
    local diff_list=$1
    local index=$2
    local diff

    if [[ ${is_rollback_list[index]} = 1 ]]; then
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

# 各サービスごとのパッケージインストールのエラー情報を保存するためのグローバル変数名を取得する。
get_error_variable_name() {
    local replaced_python_service_name=$(echo $1 | sed -e 's/-/_/g')
    echo "${replaced_python_service_name}_error_pkg_list"
}

# 各サービスごとのパッケージのインストールエラー情報のテキストを生成する。
create_error_pkg_info_text() {
    local text=""
    local error_variable_name=`get_error_variable_name "${python_service_name_list[index]}"`

    local length=$(eval echo '${#'${error_variable_name}'[@]}')
    if [ $length -ge 1 ]; then
        text="${text}\`\`\`"

        for error_pkg_info in `eval echo '${'${error_variable_name}'[@]}'`; do
            text="${text}${error_pkg_info}\n"
        done

        text="${text}\`\`\`\n"
    fi

    echo $text
}

# 差分、エラー情報を通知用のテキストとして1つにまとめる。
create_notification_text() {
    local text=""
    local index
    local diff_text

    for index in "${!python_service_name_list[@]}"; do
        local tmp_err_pkg_info_text=`create_error_pkg_info_text "$index"`
        text="${text}*${python_service_name_list[index]}*\n"
        text="${text}${tmp_err_pkg_info_text}"

        text="${text}${diff_text_list[index]}\n\n"
    done

    echo $text
}

# slack通知
send_notification() {
    local text=$1
    local channel=${channel:-'#auto-update'}
    local botname=${botname:-'pip-auto-update'}
    local emoji=${emoji:-':heartpulse:'}
    local message=`echo ${text}`
    local payload="payload={
        \"channel\": \"${channel}\",
        \"username\": \"${botname}\",
        \"icon_emoji\": \"${emoji}\",
        \"text\": \"${text}\"
    }"

    curl -s -S -X POST -d "${payload}" ${SLACK_AUTO_UPDATE_URL} > /dev/null
}

main() {
    for index in "${!python_service_name_list[@]}"; do
        local docker_exec_command="docker exec ${python_service_name_list[index]}"

        # 現在のインストール状態を一時保存（通知・pip check時のロールバック用）
        local now_pkg_list=$(${docker_exec_command} pip list --format=freeze)

        # サービスごとにエラーが起きたパッケージ名を保存
        local error_variable_name=`get_error_variable_name "${python_service_name_list[index]}"`

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
                eval ${error_variable_name}+=\(\"${tmp_pkg_info}\"\)
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
            is_rollback_list+=(1)
            diff_text_list+=("NODIFF")
        else
            is_rollback_list+=(0)
            local updated_pkg_list=$(${docker_exec_command} pip list --format=freeze)
            local diff=$(diff -u <(echo "${now_pkg_list[@]}") <(echo "${updated_pkg_list[@]}") | grep -E '(^-\w|^\+\w)')
            local tmp_diff=`create_diff_text "$diff" "$index"`

            if [ -z "$tmp_diff" ]; then
                diff_text_list+=("NODIFF")
            else
                diff_text_list+=($tmp_diff)
            fi
        fi
    done
}

main
send_notification $(create_notification_text)
