python_service_name_list=("portfolio-app" "finote-app" "shifree-app")
is_rollback_list=()
diff_text_list=()

create_diff_text() {
    diff_text=""
    diff_list=$1
    index=$2

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

create_error_pkg_info_text() {
    text=""
}

get_error_variable_name() {
    replaced_python_service_name=$(echo $1 | sed -e 's/-/_/g')
    echo "${replaced_python_service_name}_error_pkg_list"
}


create_notification_text() {
    text=""

    for index in "${!python_service_name_list[@]}"; do
        text="${text}*${python_service_name_list[index]}*\n"
        error_variable_name=`get_error_variable_name "${python_service_name_list[index]}"`

        for error_pkg_info in `eval echo '${'${error_variable_name}'[@]}'`; do
            text="${text}${error_pkg_info}\n\n"
        done

        for diff_text in ${diff_text_list[@]}; do
            text="${text}${diff_text}\n"
        done
    done

    echo $text
}

send_notification() {
    text=$1

    # echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<,"
    # echo $text

    channel=${channel:-'#health-check'}
    botname=${botname:-'health-check'}
    emoji=${emoji:-':heartpulse:'}
    message=`echo ${text}`
    payload="payload={
        \"channel\": \"${channel}\",
        \"username\": \"${botname}\",
        \"icon_emoji\": \"${emoji}\",
        \"text\": \"${message}\"
    }"

    # curl -s -S -X POST -d "${payload}" ${SLACK_HEALTH_CHECK_URL} > /dev/null
}

for index in "${!python_service_name_list[@]}"; do
    docker_exec_command="docker exec ${python_service_name_list[index]}"

    # 現在のインストール状態を一時保存（通知・pip check時のロールバック用）
    now_pkg_list=$(${docker_exec_command} pip list --format=freeze)
    # now_pkg_list=(`echo $now_pkg_list`)

    # サービスごとにエラーが起きたパッケージ名を保存
    error_variable_name=`get_error_variable_name "${python_service_name_list[index]}"`

    ${docker_exec_command} pip install -U pip

    outdated_pkg_list=$(${docker_exec_command} pip list --outdated --format=freeze | awk -F "==" '{print $1}')
    outdated_pkg_list=(`echo $outdated_pkg_list`)

    for outdated_pkg in ${outdated_pkg_list[@]}; do
        now_version=$(${docker_exec_command} pip list | grep $outdated_pkg | awk -F " " '{print $2}')
        update_error=$(${docker_exec_command} pip install -U $outdated_pkg 2>&1 > /dev/null)

        # pip installでエラーが起きた場合はバージョンを戻す
        if [ -n "$update_error" ]; then
            ${docker_exec_command} pip install "${outdated_pkg}==${now_version}"

            tmp_pkg_info="${outdated_pkg}==${now_version}--->ErrorDependency"
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
        diff_text_list+=("")
    else
        is_rollback_list+=(0)
        updated_pkg_list=$(${docker_exec_command} pip list --format=freeze)
        diff=$(diff -u <(echo "${now_pkg_list[@]}") <(echo "${updated_pkg_list[@]}") | grep -E '(^-\w|^\+\w)' | sort)
        diff_text_list+=(`create_diff_text "$diff" "$index"`)

        # echo ${updated_pkg_list[@]}
        # echo "+*****************************:"
        # echo ${now_pkg_list[@]}
        # echo "+*****************************:"
        # echo $diff
        # echo "+*****************************:"
        # echo ${diff_text_list[@]}
        
    fi

    notification_text=$(create_notification_text)
    # echo "+*****************************:"
    echo $notification_text
    # echo "+*****************************:"
    # send_notification $notification_text
    exit
done

notification_text=`create_notification_text`
send_notification $notification_text
