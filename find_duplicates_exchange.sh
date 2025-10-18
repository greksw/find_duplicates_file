#!/bin/sh

# Скрипт поиска дубликатов по имени, размеру и хэшу для TrueNAS Core
SEARCH_DIR="${1:-/mnt/data/Exchange}"
OUTPUT_FILE="${2:-/tmp/duplicates_report_$(date +%Y%m%d_%H%M%S).txt}"
MAX_DEPTH="${3:-10}"

echo "=== ПОИСК ДУБЛИКАТОВ: имя, размер, хэш ==="
echo "Директория: $SEARCH_DIR"
echo "Результат: $OUTPUT_FILE"
echo "Макс. глубина: $MAX_DEPTH"
echo ""

{
    echo "ОТЧЕТ О ДУБЛИКАТАХ ФАЙЛОВ"
    echo "Дата создания: $(date)"
    echo "Директория поиска: $SEARCH_DIR"
    echo "Критерии: имя файла, размер, MD5 хэш"
    echo "=============================================="
    echo ""

    # Временные файлы
    TEMP_ALL_FILES=$(mktemp)
    TEMP_NAME_SIZE_DUPLICATES=$(mktemp)
    TEMP_HASH_CANDIDATES=$(mktemp)
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

    # Функция для получения даты модификации
    get_mtime() {
        local file="$1"
        stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || echo "UNKNOWN"
    }

    # Функция для получения размера
    get_size() {
        local file="$1"
        stat -f%z "$file" 2>/dev/null || echo "0"
    }

    echo "1. СБОР ИНФОРМАЦИИ О ФАЙЛАХ..."
    echo "----------------------------"

    # Используем временный файл для подсчета
    TEMP_COUNTER=$(mktemp)
    echo "0" > "$TEMP_COUNTER"

    # Находим все файлы и собираем информацию (без -print0)
    find "$SEARCH_DIR" -type f -maxdepth "$MAX_DEPTH" | while IFS= read -r file; do
        counter=$(cat "$TEMP_COUNTER")
        counter=$((counter + 1))
        echo "$counter" > "$TEMP_COUNTER"
        
        if [ $((counter % 500)) -eq 0 ]; then
            echo "Обработано файлов: $counter"
        fi
        
        filename=$(basename "$file")
        dirname=$(dirname "$file")
        mtime=$(get_mtime "$file")
        size=$(get_size "$file")
        
        # Записываем информацию о файле
        echo "$filename|$size|$mtime|$dirname|$file" >> "$TEMP_ALL_FILES"
    done

    total_files=$(cat "$TEMP_COUNTER" 2>/dev/null || echo "0")
    rm -f "$TEMP_COUNTER"
    echo "Всего файлов: $total_files"
    echo ""

    # Проверяем, что файл с данными не пустой
    if [ ! -s "$TEMP_ALL_FILES" ]; then
        echo "Ошибка: Не удалось собрать информацию о файлах."
        echo "Проверьте путь: $SEARCH_DIR"
        rm -f "$TEMP_ALL_FILES" "$TEMP_NAME_SIZE_DUPLICATES" "$TEMP_HASH_CANDIDATES" "$TEMP_HASH_DUPLICATES"
        exit 1
    fi

    echo "2. ПОИСК ДУБЛИКАТОВ ПО ИМЕНИ И РАЗМЕРУ..."
    echo "----------------------------------------"

    # Дубликаты по имени и размеру
    awk -F'|' '
    {
        name = $1
        size = $2
        mtime = $3
        dir = $4
        path = $5
        
        key = name "|" size
        if (keys[key]) {
            if (!printed[key]) {
                print "\nДУБЛИКАТЫ ПО ИМЕНИ И РАЗМЕРУ: \"" name "\" (" size " байт)"
                print "Первый файл: " first_path[key] " (Дата: " first_mtime[key] ")"
                printed[key] = 1
            }
            print "Дубликат: " path " (Дата: " mtime ")"
        } else {
            keys[key] = 1
            first_path[key] = path
            first_mtime[key] = mtime
        }
    }' "$TEMP_ALL_FILES" > "$TEMP_NAME_SIZE_DUPLICATES"

    name_size_dups=$(grep -c "ДУБЛИКАТЫ ПО ИМЕНИ И РАЗМЕРУ" "$TEMP_NAME_SIZE_DUPLICATES" 2>/dev/null || echo "0")
    echo "Найдено групп дубликатов по имени и размеру: $name_size_dups"
    echo ""

    echo "3. ПРОВЕРКА ДУБЛИКАТОВ ПО ХЭШУ (MD5)..."
    echo "----------------------------------"

    hash_dups_count=0

    # Если есть дубликаты по имени и размеру, проверяем их хэши
    if [ "$name_size_dups" -gt 0 ]; then
        echo "Сбор файлов для проверки хэша..."
        
        # Извлекаем пути всех файлов-дубликатов и первых файлов
        {
            # Извлекаем "Первый файл" из отчета
            grep "Первый файл: " "$TEMP_NAME_SIZE_DUPLICATES" | sed 's/.*Первый файл: //' | cut -d' ' -f1
            # Извлекаем "Дубликат" из отчета  
            grep "Дубликат: " "$TEMP_NAME_SIZE_DUPLICATES" | sed 's/.*Дубликат: //' | cut -d' ' -f1
        } | sort -u > "$TEMP_HASH_CANDIDATES"

        total_candidates=$(wc -l < "$TEMP_HASH_CANDIDATES" 2>/dev/null | tr -d ' ' || echo "0")
        echo "Файлов для проверки хэша: $total_candidates"
        
        if [ "$total_candidates" -gt 0 ]; then
            echo "Вычисление хэшей..."

            # Вычисляем хэши для кандидатов
            hash_counter=0
            while IFS= read -r file; do
                if [ -f "$file" ]; then
                    hash_counter=$((hash_counter + 1))
                    if [ $((hash_counter % 100)) -eq 0 ]; then
                        echo "Вычислено хэшей: $hash_counter/$total_candidates"
                    fi
                    
                    hash=$(get_md5 "$file")
                    if [ "$hash" != "ERROR" ]; then
                        filename=$(basename "$file")
                        size=$(get_size "$file")
                        echo "$hash|$filename|$size|$file"
                    else
                        echo "Ошибка вычисления хэша для: $file" >&2
                    fi
                else
                    echo "Файл не найден: $file" >&2
                fi
            done < "$TEMP_HASH_CANDIDATES" > "$TEMP_HASH_DUPLICATES.raw"

            echo "Вычисление хэшей завершено."
            echo ""

            # Сортируем по хэшу и ищем дубликаты
            sort "$TEMP_HASH_DUPLICATES.raw" > "$TEMP_HASH_DUPLICATES"

            # Группируем по хэшу и выводим результаты
            echo "=== ТОЧНЫЕ ДУБЛИКАТЫ (ПО ХЭШУ) ==="
            
            # Используем awk для группировки по хэшу
            awk -F'|' '
            BEGIN {
                count = 0
            }
            {
                hash = $1
                filename = $2
                size = $3
                path = $4
                
                # Сохраняем информацию о файле в массиве по хэшу
                if (hash in files) {
                    # Если это второй файл с таким хэшем, то начинаем группу
                    if (!printed[hash]) {
                        print "\nТОЧНЫЕ ДУБЛИКАТЫ (хэш: " hash ")"
                        print "Файл: " first_filename[hash] " (" first_size[hash] " байт)"
                        print "Первый файл: " first_path[hash]
                        printed[hash] = 1
                        count++
                        # Не выводим первый файл как дубликат, только второй и последующие
                    }
                    print "Дубликат: " path
                } else {
                    # Первый файл с таким хэшем
                    files[hash] = 1
                    first_path[hash] = path
                    first_filename[hash] = filename
                    first_size[hash] = size
                }
            }
            END {
                if (count == 0) {
                    print "Точные дубликаты не найдены."
                } else {
                    print "\nВсего групп точных дубликатов: " count
                }
            }' "$TEMP_HASH_DUPLICATES" > "$TEMP_HASH_DUPLICATES.report"

            # Считаем количество групп дубликатов по хэшу
            hash_dups_count=$(grep -c "ТОЧНЫЕ ДУБЛИКАТЫ" "$TEMP_HASH_DUPLICATES.report" 2>/dev/null || echo "0")
            
            cat "$TEMP_HASH_DUPLICATES.report"
        else
            echo "Нет файлов для проверки хэша."
        fi
    else
        echo "Нет дубликатов для проверки хэша."
    fi

    echo ""
    echo "4. ФОРМИРОВАНИЕ ОТЧЕТА..."
    echo "-----------------------"

    # Объединяем все результаты
    echo "=== ДУБЛИКАТЫ ПО ИМЕНИ И РАЗМЕРУ ==="
    if [ -s "$TEMP_NAME_SIZE_DUPLICATES" ]; then
        cat "$TEMP_NAME_SIZE_DUPLICATES"
    else
        echo "Дубликаты по имени и размеру не найдены."
    fi
    echo ""
    
    echo "=== ТОЧНЫЕ ДУБЛИКАТЫ (ПО ХЭШУ) ==="
    if [ -f "$TEMP_HASH_DUPLICATES.report" ]; then
        cat "$TEMP_HASH_DUPLICATES.report"
    else
        echo "Точные дубликаты не найдены."
    fi
    echo ""

    echo "=============================================="
    echo "СТАТИСТИКА:"
    echo "Всего файлов проверено: $total_files"
    echo "Дубликатов по имени и размеру: $name_size_dups групп"
    echo "Точных дубликатов (по хэшу): $hash_dups_count групп"
    echo ""
    echo "Отчет сохранен: $OUTPUT_FILE"

    # Очистка временных файлов
    rm -f "$TEMP_ALL_FILES" "$TEMP_NAME_SIZE_DUPLICATES" "$TEMP_HASH_CANDIDATES" "$TEMP_HASH_DUPLICATES" "$TEMP_HASH_DUPLICATES.raw" "$TEMP_HASH_DUPLICATES.report"

} 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "=== ЗАВЕРШЕНО ==="
echo "Полный отчет: $OUTPUT_FILE"
