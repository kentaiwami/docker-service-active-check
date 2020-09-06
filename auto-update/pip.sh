#!/bin/bash

. ./common.sh
. ../.env

service_names=("portfolio-app")
script_path=$(cd $(dirname $0); pwd)

update_requirements() {
    local index=$1
    local file_path="${REQUIREMENTS_FOLDER_PATH_LIST[index]}requirements.txt"

    docker exec -i ${service_names[index]} pip freeze > $file_path
}

update() {
    local index=$1
    local is_skip=$2
    local outdated_pkg
    local error_pkg_info_list=()
    local docker_exec_command="docker exec -i ${service_names[index]}"

    # docker execが失敗するサービスは以降の処理を実施しない
    if [ $is_skip -eq 1 ]; then
        write_csv "error_pkg" $index ""
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${service_names[index]}* is Skip\n"
        exit
    fi

    write_csv "skip" $index ""

    ${docker_exec_command} pip install -U pip --user 2>/dev/null
    
    local outdated_pkg_list=$(${docker_exec_command} pip list --outdated --format=freeze | awk -F "==" '{print $1}')
    local outdated_pkg_list=(`echo $outdated_pkg_list`)

    for outdated_pkg in ${outdated_pkg_list[@]}; do
        local now_version=$(${docker_exec_command} pip list | grep $outdated_pkg | awk -F " " '{print $2}')
        local update_error=$(${docker_exec_command} pip install -U $outdated_pkg --user 2>&1 > /dev/null | grep ERROR)

        # pip installでエラーが起きた場合はバージョンを戻す
        if [ -n "$update_error" ]; then
            ${docker_exec_command} pip install "${outdated_pkg}==${now_version}" --user

            local tmp_pkg_info="${outdated_pkg}==${now_version}"
            error_pkg_info_list+=($tmp_pkg_info)
        fi
    done

    ${docker_exec_command} pip check
    status=$?

    # 依存関係が解消されない場合はrequirements.txtを更新せずに再起動で元に戻す
    if [ $status = 1 ]; then
        write_csv "is_rollback" $index 1
    else
        write_csv "is_rollback" $index 0

        local error_pkg_info_text=$(create_error_pkg_text ${error_pkg_info_list[@]})
        write_csv "error_pkg" $index $error_pkg_info_text

        update_requirements $index
        git_push_submodule $index ${REQUIREMENTS_FOLDER_PATH_LIST[index]} ${PIP_REPOSITORY_NAME_LIST[index]}
    fi
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

main ${#service_names[@]} "pip freeze" "pip-auto-update" "https://img.icons8.com/color/480/000000/python.png" ${service_names[@]} ${PIP_REPOSITORY_NAME_LIST[@]} ${PIP_DOCKER_COMPOSE_FILE_PATH_LIST[@]}
