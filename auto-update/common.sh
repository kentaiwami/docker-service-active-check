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