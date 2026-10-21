#!/bin/bash

# Copyright (c) 2026 [@capitan_nemo_spb]
# 
# Данная лицензия разрешает лицам, получившим копию данного программного 
# обеспечения и сопутствующей документации (в дальнейшем именуемого "Программное 
# обеспечение"), безвозмездно использовать Программное обеспечение без ограничений, 
# включая неограниченное право на использование, копирование, изменение, слияние, 
# публикацию, распространение, сублицензирование и/или продажу копий Программного 
# обеспечения, а также лицам, которым предоставляется данное Программное 
# обеспечение, при соблюдении следующих условий:
# 
# Указанное выше уведомление об авторских правах и данные условия лицензии должны 
# быть включены во все копии или значимые части Программного обеспечения.
# 
# ПРОГРАММНОЕ ОБЕСПЕЧЕНИЕ ПРЕДОСТАВЛЯЕТСЯ "КАК ЕСТЬ", БЕЗ КАКИХ-ЛИБО ГАРАНТИЙ, 
# ВЫРАЖЕННЫХ ИЛИ ПОДРАЗУМЕВАЕМЫХ, ВКЛЮЧАЯ НЕ ОГРАНИЧИВАЯСЬ ГАРАНТИЯМИ ТОВАРНОЙ 
# ПРИГОДНОСТИ, СООТВЕТСТВИЯ ПО НАЗНАЧЕНИЮ И НЕНАРУШЕНИЯ ПРАВ. НИ В КАКОМ СЛУЧАЕ 
# АВТОРЫ ИЛИ ПРАВООБЛАДАТЕЛИ НЕ НЕСУТ ОТВЕТСТВЕННОСТИ ПО КАКИМ-ЛИБО ИСКАМ, ЗА 
# УЩЕРБ ИЛИ ПО ИНЫМ ТРЕБОВАНИЯМ, ВОЗНИКШИМ В СВЯЗИ С ПРОГРАММНЫМ ОБЕСПЕЧЕНИЕМ ИЛИ 
# ИСПОЛЬЗОВАНИЕМ ПРОГРАММНОГО ОБЕСПЕЧЕНИЯ.

set -euo pipefail

PROGNAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

usage() {
    cat <<EOF
Использование программы: $PROGNAME параметр1 параметр2
Первый параметр это номер обновляемой версии 1С, если 0 то чистая установка
Второй параметр это номер новой версии 1С
Файл установки 1С должен находиться в одном каталоге со скриптом
Если указан номер обновляемой версии 1С, то должен существовать каталог установки
Пример: $PROGNAME 0 8.3.24.1586
Пример: $PROGNAME 8.3.23.1586 8.3.24.1586
EOF
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

err() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ОШИБКА: $*" >&2
}

replace_version_in_file() {
    local target_file="$1"
    if [[ -f "$target_file" ]]; then
        perl -pE "s/\Q${old_version}\E/${new_version}/g" -i "$target_file"
    fi
}

http_replace_version() {
    local conf_file="$1"
    if grep -qF "${old_version}" "${conf_file}"; then
        log "Изменяется версия в файле веб-публикации: ${conf_file}"
        perl -i".bak_${current_date}" -pE "s/\Q${old_version}\E/${new_version}/g" "${conf_file}"
    fi
}

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    usage
    exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
    err "Скрипт должен быть запущен с правами администратора"
    exit 1
fi

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

old_version=$1
new_version=$2
current_date=$(date +'%Y%m%d_%H%M%S')
bak_dir="${SCRIPT_DIR}/bak_${current_date}"

log "Проверяется существование архива/файла установки"
new_archive="${SCRIPT_DIR}/server64_${new_version//./_}.zip"

shopt -s nullglob
installer_matches=( "${SCRIPT_DIR}"/*-"${new_version}"-*.run )
shopt -u nullglob

if [[ ${#installer_matches[@]} -eq 0 ]]; then
    if [[ -f "${new_archive}" ]]; then
        log "Разархивируется ${new_archive}..."
        unzip -o "${new_archive}" -d "${SCRIPT_DIR}" "*${new_version}*.run"
        shopt -s nullglob
        installer_matches=( "${SCRIPT_DIR}"/*-"${new_version}"-*.run )
        shopt -u nullglob
    else
        err "Не обнаружен файл установки или архива новой версии 1С ${new_archive}"
        exit 1
    fi
fi

if [[ ${#installer_matches[@]} -eq 0 || ! -f "${installer_matches[0]}" ]]; then
    err "Не обнаружен файл установки новой версии 1С"
    exit 1
fi

new_file="${installer_matches[0]}"
chmod +x "${new_file}"

old_dir="/opt/1cv8/x86_64/${old_version}"
new_dir="/opt/1cv8/x86_64/${new_version}"
srv_suffixes=()
ras_suffixes=()

if [[ "${old_version}" != "0" ]]; then
    log "Старая версия не 0 (${old_version}), проверяется существование каталога установки"
    if [[ ! -f "${old_dir}/uninstaller-full" ]]; then
        err "Не обнаружен каталог обновляемой версии 1C ${old_version}"
        exit 1
    fi

    mkdir -p "${bak_dir}"
    log "Сохраняются файлы старых служб с возможными нетиповыми настройками"

    # Поиск всех служб сервера 1С вида srv1cv8-OLD_VER@.service, srv1cv8-OLD_VER@2541.service и т.д.
    shopt -s nullglob
    old_srv_services=( "${old_dir}"/srv1cv8-"${old_version}"@*.service )
    shopt -u nullglob

    if [[ ${#old_srv_services[@]} -eq 0 ]]; then
        log "Службы srv1cv8 не найдены в ${old_dir}, используется шаблон по умолчанию"
        srv_suffixes+=( "" )
    else
        for srv_path in "${old_srv_services[@]}"; do
            srv_file="$(basename "${srv_path}")"
            # Извлекаем суффикс после @ и до .service (например: "" или "2541")
            suffix="${srv_file#srv1cv8-${old_version}@}"
            suffix="${suffix%.service}"
            srv_suffixes+=( "${suffix}" )

            new_srv_name="srv1cv8-${new_version}@${suffix}.service"
            log "Резервное копирование и адаптация службы: ${srv_file} -> ${new_srv_name}"
            cp "${srv_path}" "${bak_dir}/${new_srv_name}"
            replace_version_in_file "${bak_dir}/${new_srv_name}"
        done
    fi

    # Поиск всех служб RAS вида ras-OLD_VER.service, ras-OLD_VER-2545.service, ras-OLD_VER@.service и т.д.
    shopt -s nullglob
    old_ras_services=( "${old_dir}"/ras-"${old_version}"*.service )
    shopt -u nullglob

    if [[ ${#old_ras_services[@]} -eq 0 ]]; then
        log "Службы RAS не найдены в ${old_dir}"
    else
        for ras_path in "${old_ras_services[@]}"; do
            ras_file="$(basename "${ras_path}")"
            # Извлекаем суффикс после ras-${old_version} и до .service (например: "" для ras-8.3.23.service, "-2545" или "@2545")
            suffix="${ras_file#ras-${old_version}}"
            suffix="${suffix%.service}"
            ras_suffixes+=( "${suffix}" )

            new_ras_name="ras-${new_version}${suffix}.service"
            log "Резервное копирование и адаптация службы RAS: ${ras_file} -> ${new_ras_name}"
            cp "${ras_path}" "${bak_dir}/${new_ras_name}"
            replace_version_in_file "${bak_dir}/${new_ras_name}"
        done
    fi

    log "Останавливается старая версия платформы 1С"
    for suffix in "${srv_suffixes[@]}"; do
        inst="default"
        [[ -n "${suffix}" ]] && inst="${suffix}"

        srv_unit="srv1cv8-${old_version}@${suffix}.service"
        srv_inst="srv1cv8-${old_version}@${inst}.service"

        systemctl stop "${srv_inst}" 2>/dev/null || true
        systemctl disable "${srv_inst}" 2>/dev/null || true

        for unit_link in \
            "/etc/systemd/system/${srv_unit}" \
            "/etc/systemd/system/${srv_inst}" \
            "/etc/systemd/system/multi-user.target.wants/${srv_inst}"
        do
            if [[ -e "${unit_link}" || -L "${unit_link}" ]]; then
                rm -f "${unit_link}"
            fi
        done
    done

    log "Останавливаются старые службы RAS"
    for suffix in "${ras_suffixes[@]}"; do
        ras_unit="ras-${old_version}${suffix}.service"

        # Если служба шаблонная (содержит @), определяем имя инстанса
        if [[ "${suffix}" == *"@"* ]]; then
            inst_suffix="${suffix#*@}"
            [[ -z "${inst_suffix}" ]] && inst_suffix="default"
            ras_inst="ras-${old_version}@${inst_suffix}.service"
        else
            ras_inst="${ras_unit}"
        fi

        systemctl stop "${ras_inst}" 2>/dev/null || true
        systemctl disable "${ras_inst}" 2>/dev/null || true

        for unit_link in \
            "/etc/systemd/system/${ras_unit}" \
            "/etc/systemd/system/${ras_inst}" \
            "/etc/systemd/system/multi-user.target.wants/${ras_inst}"
        do
            if [[ -e "${unit_link}" || -L "${unit_link}" ]]; then
                rm -f "${unit_link}"
            fi
        done
    done

    systemctl daemon-reload
    systemctl reset-failed "srv1cv8-*" "ras-*" 2>/dev/null || true
else
    srv_suffixes+=( "" )
    ras_suffixes+=( "" )
fi
log "Производится установка новой версии платформы 1С (${new_version})..."
"${new_file}" --mode unattended --enable-components "server,ws,server_admin,additional_admin_functions,liberica_jre,ru"

log "Проверяется, что новая версия установилась..."
new_service="${new_dir}/srv1cv8-${new_version}@.service"
if [[ ! -f "${new_service}" ]]; then
    err "Некорректно установилась новая версия 1C: файл ${new_service} не найден"
    exit 1
fi

if [[ "${old_version}" != "0" ]]; then
    log "Удаляется старая версия платформы 1С (${old_version})..."
    "${old_dir}/uninstaller-full" --mode unattended

    log "Восстановление конфигураций служб srv1cv8..."
    for suffix in "${srv_suffixes[@]}"; do
        target_srv="srv1cv8-${new_version}@${suffix}.service"
        bak_srv_file="${bak_dir}/${target_srv}"
        dest_srv_file="${new_dir}/${target_srv}"

        if [[ -f "${bak_srv_file}" ]]; then
            if [[ -f "${dest_srv_file}" ]]; then
                mv "${dest_srv_file}" "${bak_dir}/${target_srv}.dist"
            fi
            log "Копирование файла службы: ${target_srv} -> ${new_dir}/"
            cp "${bak_srv_file}" "${dest_srv_file}"
        fi
    done

    log "Восстановление конфигураций служб RAS..."
    for suffix in "${ras_suffixes[@]}"; do
        target_ras="ras-${new_version}${suffix}.service"
        bak_ras_file="${bak_dir}/${target_ras}"
        dest_ras_file="${new_dir}/${target_ras}"

        if [[ -f "${bak_ras_file}" ]]; then
            if [[ -f "${dest_ras_file}" ]]; then
                mv "${dest_ras_file}" "${bak_dir}/${target_ras}.dist"
            fi
            log "Копирование файла службы RAS: ${target_ras} -> ${new_dir}/"
            cp "${bak_ras_file}" "${dest_ras_file}"
        fi
    done
fi

log "Запускаются службы 1С..."
systemctl daemon-reload

for suffix in "${srv_suffixes[@]}"; do
    inst="default"
    [[ -n "${suffix}" ]] && inst="${suffix}"

    srv_unit_file="${new_dir}/srv1cv8-${new_version}@${suffix}.service"
    srv_inst_name="srv1cv8-${new_version}@${inst}"

    if [[ -f "${srv_unit_file}" ]]; then
        systemctl link "${srv_unit_file}"
        systemctl enable "${srv_inst_name}" --now
    else
        err "Файл службы ${srv_unit_file} не найден для регистрации!"
    fi
done

for suffix in "${ras_suffixes[@]}"; do
    ras_unit_file="${new_dir}/ras-${new_version}${suffix}.service"

    if [[ "${suffix}" == *"@"* ]]; then
        inst_suffix="${suffix#*@}"
        [[ -z "${inst_suffix}" ]] && inst_suffix="default"
        ras_inst_name="ras-${new_version}@${inst_suffix}"
    else
        ras_inst_name="ras-${new_version}${suffix}.service"
    fi

    if [[ -f "${ras_unit_file}" ]]; then
        systemctl link "${ras_unit_file}"
        systemctl enable "${ras_inst_name}" --now
    fi
done

log "Ожидание запуска служб..."
for ((i=0; i<15; i++)); do
    all_active=true
    for suffix in "${srv_suffixes[@]}"; do
        inst="default"
        [[ -n "${suffix}" ]] && inst="${suffix}"
        if ! systemctl is-active --quiet "srv1cv8-${new_version}@${inst}"; then
            all_active=false
            break
        fi
    done

    if [[ "${all_active}" == "true" ]]; then
        for suffix in "${ras_suffixes[@]}"; do
            ras_unit_file="${new_dir}/ras-${new_version}${suffix}.service"
            [[ ! -f "${ras_unit_file}" ]] && continue

            if [[ "${suffix}" == *"@"* ]]; then
                inst_suffix="${suffix#*@}"
                [[ -z "${inst_suffix}" ]] && inst_suffix="default"
                ras_inst_name="ras-${new_version}@${inst_suffix}"
            else
                ras_inst_name="ras-${new_version}${suffix}.service"
            fi

            if ! systemctl is-active --quiet "${ras_inst_name}"; then
                all_active=false
                break
            fi
        done
    fi

    if [[ "${all_active}" == "true" ]]; then
        log "Все службы успешно перешли в активное состояние."
        break
    fi
    sleep 2
done

for suffix in "${srv_suffixes[@]}"; do
    inst="default"
    [[ -n "${suffix}" ]] && inst="${suffix}"
    systemctl status "srv1cv8-${new_version}@${inst}" --no-pager -l || true
done

for suffix in "${ras_suffixes[@]}"; do
    ras_unit_file="${new_dir}/ras-${new_version}${suffix}.service"
    [[ ! -f "${ras_unit_file}" ]] && continue

    if [[ "${suffix}" == *"@"* ]]; then
        inst_suffix="${suffix#*@}"
        [[ -z "${inst_suffix}" ]] && inst_suffix="default"
        ras_inst_name="ras-${new_version}@${inst_suffix}"
    else
        ras_inst_name="ras-${new_version}${suffix}.service"
    fi

    systemctl status "${ras_inst_name}" --no-pager -l || true
done

if [[ "${old_version}" != "0" ]]; then
    web_conf_dirs=()
    [[ -d '/etc/httpd' ]] && web_conf_dirs+=( '/etc/httpd' )
    [[ -d '/etc/apache2' ]] && web_conf_dirs+=( '/etc/apache2' )

    if [[ ${#web_conf_dirs[@]} -gt 0 ]]; then
        for conf_dir in "${web_conf_dirs[@]}"; do
            readarray -d '' -t find_files < <(find "${conf_dir}" -name '*.conf' -size +1c -type f -print0)
            for file_path in "${find_files[@]}"; do
                http_replace_version "${file_path}"
            done
        done

        log "Перезапускается веб-сервер..."
        if systemctl list-unit-files 2>/dev/null | grep -qE '^(httpd|apache2)\.service'; then
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null || true
        fi
    fi
fi

log "Обновление/установка платформы 1С успешно завершена!"
