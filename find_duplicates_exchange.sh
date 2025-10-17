#!/bin/sh

# Скрипт поиска дубликатов с последовательной фильтрацией для TrueNAS
SEARCH_DIR="${1:-/mnt/data/Exchange}"
OUTPUT_FILE="${2:-/tmp/real_duplicates_$(date +%Y%m%d_%H%M%S).txt}"
MAX_DEPTH="${3:-10}"

echo "=== ПОИСК РЕАЛЬНЫХ ДУБЛИКАТОВ: имя → дата/размер → хэш ==="
echo "Директория: $SEARCH_DIR"
echo "Результат: $OUTPUT_FILE"
echo "Макс. глубина: $MAX_DEPTH"
echo ""

# Временные файлы
TEMP_ALL_FILES=$(mktemp)
TEMP_NAME_DUPLICATES=$(mktemp)
TEMP_DATE_DUPLICATES=$(mktemp)
TEMP_HASH_DUPLICATES=$(mktemp)

# Функция для получения MD5 хэша (FreeBSD)
get_md5() {
    local file="$1"
    if command -v md5 >/dev/null 2>&1; then
        md5 -q "$file" 2>/dev/null || echo "ERROR"
    else
        md5sum "$file" 2>/dev/null | awk '{print $1}' || echo "ERROR"
    fi
}

# Функция для обработки группы файлов
process_group() {
    local group_files="$1"
    local key="$2"
    
    # Разбиваем ключ на составляющие
    name=$(echo "$key" | cut -d'|' -f1)
    mtime=$(echo "$key" | cut -d'|' -f2)
    size=$(echo "$key" | cut -d'|' -f3)
    
    first_file=""
    
    # Временный файл для хэшей в группе
    TEMP_GROUP_HASHES=$(mktemp)
    
    # Вычисляем хэши для всех файлов в группе
    echo "$group_files" | while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        if [ -z "$first_file" ]; then
            first_file="$file"
        fi
        
        hash=$(get_md5 "$file")
        if [ "$hash" != "ERROR" ]; then
            echo "$hash|$file" >> "$TEMP_GROUP_HASHES"
        fi
    done
    
    # Ищем дубликаты по хэшу в группе
    if [ -f "$TEMP_GROUP_HASHES" ] && [ -s "$TEMP_GROUP_HASHES" ]; then
        sort "$TEMP_GROUP_HASHES" | awk -F'|' '
        BEGIN { printed_group = 0 }
        {
            hash = $1
            file = $2
            if (hash == prev_hash) {
                if (!printed_group) {
                    print ""
                    print "РЕАЛЬНЫЕ ДУБЛИКАТЫ: \"" name "\" (" mtime ", " size " байт)"
                    print "Первый файл: " first_file
                    printed_group = 1
                }
                print "Дубликат: " file
            }
            prev_hash = hash
        }' name="$name" mtime="$mtime" size="$size" first_file="$first_file" >> "$TEMP_HASH_DUPLICATES"
    fi
    
    rm -f "$TEMP_GROUP_HASHES"
}

# Основной процесс
{
    echo "ОТЧЕТ О РЕАЛЬНЫХ ДУБЛИКАТАХ ФАЙЛОВ"
    echo "Дата создания: $(date)"
    echo "Директория поиска: $SEARCH_DIR"
    echo "Критерии: одинаковое имя → одинаковая дата/размер → одинаковый хэш"
    echo "=============================================="
    echo ""

    echo "1. СБОР ИНФОРМАЦИИ О ФАЙЛАХ..."
    echo "----------------------------"

    # Находим все файлы и собираем информацию
    counter=0
    find "$SEARCH_DIR" -type f -maxdepth "$MAX_DEPTH" -exec sh -c '
        filename=$(basename "$1")
        dirname=$(dirname "$1")
        mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$1" 2>/dev/null || echo "UNKNOWN")
        size=$(stat -f%z "$1" 2>/dev/null || echo "0")
        echo "$filename|$mtime|$size|$dirname|$1"
    ' _ {} \; > "$TEMP_ALL_FILES"

    total_files=$(wc -l < "$TEMP_ALL_FILES")
    echo "Всего файлов: $total_files"
    echo ""

    echo "2. ФИЛЬТРАЦИЯ: ДУБЛИКАТЫ ПО ИМЕНИ..."
    echo "-----------------------------------"

    # Находим файлы с одинаковыми именами
    awk -F'|' '
    {
        name = $1
        mtime = $2
        size = $3
        dir = $4
        path = $5
        
        if (names[name]) {
            print $0
            if (!printed[name]) {
                print first_line[name]
                printed[name] = 1
            }
        } else {
            names[name] = 1
            first_line[name] = $0
        }
    }' "$TEMP_ALL_FILES" > "$TEMP_NAME_DUPLICATES"

    name_dups=$(awk -F'|' '{print $1}' "$TEMP_NAME_DUPLICATES" | sort -u | wc -l)
    echo "Найдено файлов-кандидатов по имени: $(wc -l < "$TEMP_NAME_DUPLICATES")"
    echo "Уникальных имен с дубликатами: $name_dups"
    echo ""

    echo "3. ФИЛЬТРАЦИЯ: ДУБЛИКАТЫ ПО ДАТЕ/РАЗМЕРУ..."
    echo "------------------------------------------"

    # Среди файлов с одинаковыми именами ищем одинаковые дату/размер
    awk -F'|' '
    {
        name = $1
        mtime = $2
        size = $3
        dir = $4
        path = $5
        
        key = name "|" mtime "|" size
        if (dates[key]) {
            print $0
            if (!printed[key]) {
                print first_line[key]
                printed[key] = 1
            }
        } else {
            dates[key] = 1
            first_line[key] = $0
        }
    }' "$TEMP_NAME_DUPLICATES" > "$TEMP_DATE_DUPLICATES"

    date_dups=$(awk -F'|' '{key = $1 "|" $2 "|" $3; if (!seen[key]++) count++} END {print count}' "$TEMP_DATE_DUPLICATES")
    echo "Найдено файлов-кандидатов по дате/размеру: $(wc -l < "$TEMP_DATE_DUPLICATES")"
    echo "Уникальных групп имя+дата+размер: $date_dups"
    echo ""

    echo "4. ФИНАЛЬНАЯ ПРОВЕРКА: ДУБЛИКАТЫ ПО ХЭШУ..."
    echo "------------------------------------------"

    # Обрабатываем группы файлов для проверки хэша
    awk -F'|' '
    {
        name = $1
        mtime = $2 
        size = $3
        path = $5
        
        key = name "|" mtime "|" size
        group[key] = group[key] path "\n"
    }
    END {
        for (key in group) {
            print "GROUP:" key
            printf "%s", group[key]
            print ""  # разделитель между группами
        }
    }' "$TEMP_DATE_DUPLICATES" > "${TEMP_HASH_DUPLICATES}.tmp"

    # Обрабатываем группы и вычисляем хэши
    group_processed=0
    current_files=""
    current_key=""
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "^GROUP:"; then
            # Обрабатываем предыдущую группу
            if [ -n "$current_files" ] && [ -n "$current_key" ]; then
                process_group "$current_files" "$current_key"
                group_processed=$((group_processed + 1))
            fi
            current_key=$(echo "$line" | cut -d: -f2-)
            current_files=""
        elif [ -n "$line" ]; then
            current_files="${current_files}${line}"$'\n'
        fi
    done < "${TEMP_HASH_DUPLICATES}.tmp"

    # Обрабатываем последнюю группу
    if [ -n "$current_files" ] && [ -n "$current_key" ]; then
        process_group "$current_files" "$current_key"
        group_processed=$((group_processed + 1))
    fi

    echo "Обработано групп: $group_processed"
    hash_dups=$(grep -c "РЕАЛЬНЫЕ ДУБЛИКАТЫ:" "$TEMP_HASH_DUPLICATES" 2>/dev/null || echo "0")
    echo "Найдено групп реальных дубликатов: $hash_dups"
    echo ""

    echo "5. ФИНАЛЬНЫЙ ОТЧЕТ..."
    echo "-------------------"

    if [ -f "$TEMP_HASH_DUPLICATES" ] && [ -s "$TEMP_HASH_DUPLICATES" ]; then
        cat "$TEMP_HASH_DUPLICATES"
    else
        echo "Реальных дубликатов не найдено."
    fi

    echo ""
    echo "=============================================="
    echo "СТАТИСТИКА ФИЛЬТРАЦИИ:"
    echo "Всего файлов проверено: $total_files"
    echo "Файлов с одинаковыми именами: $(wc -l < "$TEMP_NAME_DUPLICATES" 2>/dev/null || echo 0)"
    echo "Файлов с одинаковыми именами+датами+размерами: $(wc -l < "$TEMP_DATE_DUPLICATES" 2>/dev/null || echo 0)"
    echo "Реальных дубликатов (прошли все фильтры): $hash_dups групп"

} | tee "$OUTPUT_FILE"

# Очистка временных файлов
cleanup() {
    rm -f "$TEMP_ALL_FILES" "$TEMP_NAME_DUPLICATES" "$TEMP_DATE_DUPLICATES" "$TEMP_HASH_DUPLICATES" "${TEMP_HASH_DUPLICATES}.tmp"
}

trap cleanup EXIT

echo ""
echo "=== ЗАВЕРШЕНО ==="
echo "Финальный отчет только с реальными дубликатами: $OUTPUT_FILE"
