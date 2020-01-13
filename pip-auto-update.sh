python_service_name_list=("portfolio-app" "finote-app" "shifree-app")
is_rollback_list=()
text_list=()

create_text() {
    text=""
    diff_list=$1

    for index in "${!python_service_name_list[@]}"; do
        if [ ${is_rollback_list[index]} = 1 ]; then
            text="${text}*${python_service_name_list[index]}*\n\`rollback\`\n"
        else
            text="${text}*${python_service_name_list[index]}*\n\`\`\`"
            for diff in ${diff_list[@]}; do
                text="${text}${diff}\n"
            done

            text="${text}\`\`\`\n\n"
        fi
    done
}

get_error_variable_name() {
    replaced_python_service_name=$(echo $1 | sed -e 's/-/_/g')
    echo "${replaced_python_service_name}_error_pkg_list"
}

send_notification() {
    echo ${portfolio_app_error_pkg_list[@]}

    echo "********************************"
    echo ${is_rollback_list[@]}
    echo ${text_list[@]}

    # for python_service_name in ${python_service_name_list[@]}; do
        # variable_name=`get_error_variable_name "${python_service_name}"`
        # 
    # done
    # text=""

    # for ok_service_name in ${ok_list[@]}; do
    #     text="${text}:white_check_mark: *${ok_service_name}* \n\n"
    # done

    # for index in "${!ng_list[@]}"; do
    #     text="${text}:x: *${ng_list[$index]}* ${cause_list[$index]} \n\n"
    # done

    # channel=${channel:-'#health-check'}
    # botname=${botname:-'health-check'}
    # emoji=${emoji:-':heartpulse:'}
    # message=`echo ${text}`
    # payload="payload={
    #     \"channel\": \"${channel}\",
    #     \"username\": \"${botname}\",
    #     \"icon_emoji\": \"${emoji}\",
    #     \"text\": \"${message}\"
    # }"

    # curl -s -S -X POST -d "${payload}" ${SLACK_HEALTH_CHECK_URL} > /dev/null
}

for python_service_name in ${python_service_name_list[@]}; do
    docker_exec_command="docker exec ${python_service_name}"

    # 現在のインストール状態を一時保存（通知・pip check時のロールバック用）
    now_pkg_list=$(${docker_exec_command} pip list --format=freeze)
    # now_pkg_list=(`echo $now_pkg_list`)

    # サービスごとにエラーが起きたパッケージ名を保存
    error_variable_name=`get_error_variable_name "${python_service_name}"`

    ${docker_exec_command} pip install -U pip

    outdated_pkg_list=$(${docker_exec_command} pip list --outdated --format=freeze | awk -F "==" '{print $1}')
    outdated_pkg_list=(`echo $outdated_pkg_list`)

    for outdated_pkg in ${outdated_pkg_list[@]}; do
        now_version=$(${docker_exec_command} pip list | grep $outdated_pkg | awk -F " " '{print $2}')
        update_error=$(${docker_exec_command} pip install -U $outdated_pkg 2>&1 > /dev/null)

        # pip installでエラーが起きた場合はバージョンを戻す
        if [ -n "$update_error" ]; then
            ${docker_exec_command} pip install "${outdated_pkg}==${now_version}"

            tmp_pkg_info="${outdated_pkg}==${now_version} "
            tmp_err_msg="\`Error Dependency\`"
            join=${tmp_pkg_info}''${tmp_err_msg}
            eval ${error_variable_name}+=\(\"'${join}'\"\)
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
        text_list+=("")
    else
        is_rollback_list+=(0)
        updated_pkg_list=$(${docker_exec_command} pip list --format=freeze)
        diff=$(diff -u <(echo "${now_pkg_list[@]}") <(echo "${updated_pkg_list[@]}") | grep -E '(^-\w|^\+\w)')
        text_list+=(`create_text "$diff"`)
    fi

    send_notification
done
