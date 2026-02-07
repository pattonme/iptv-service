#!/bin/bash
# GitHub IPTV自动化脚本（已降低验证规则）

SOURCE_FILE="./sources/public-sources.txt"
TEMP_M3U="./dist/iptv-temp.m3u"
FINAL_M3U="./dist/iptv-valid.m3u"
LOG_FILE="./dist/iptv-verify.log"
CONNECT_TIMEOUT=20  # 延长连接超时
STREAM_TIMEOUT=25   # 延长流超时时间
MIN_BITRATE=200000  # 大幅降低最低码率要求
SUPPORT_CODECS=("h264" "hevc" "mpeg4" "mpeg2video")  # 增加支持的编码格式
SUPPORT_RESOLUTIONS=("480p" "720p" "1080p")  # 增加480p分辨率支持
GROUP_RULES=(
    "卫视:央视|CCTV|中央电视台|湖南卫视|浙江卫视|江苏卫视|东方卫视|北京卫视|广东卫视|山东卫视|河南卫视"
    "地方台:北京|上海|广东|深圳|江苏|浙江|四川|重庆|天津|湖北|湖南|河南|河北|福建|安徽"
    "影视:电影|剧场|影视|综艺|综艺|王牌对王牌|快乐剧场"
    "新闻:新闻|资讯|财经|法治|国际|民生|时间|朝闻天下|新闻"
    "体育:体育|CCTV5+|赛事|奥运|足球|英超|NBA|中超"
    "海外:香港|台湾|澳门|TVB|凤凰|翡翠|明珠|国际|星空"
    "少儿:少儿|卡通|动漫|宝贝|早教|金鹰卡通|央少|少儿"
    "戏曲:戏曲|京剧|越剧|黄梅戏|豫剧|秦腔|梨园"
)

# 创建输出目录
mkdir -p ./dist

# 清空临时文件和日志
> $TEMP_M3U
> $FINAL_M3U
> $LOG_FILE

echo "[$(date +'%Y-%m-%d %H:%M:%S')] 启动GitHub IPTV自动验证流程..." >> $LOG_FILE

# 1. 拉取并合并源
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 拉取公开IPTV源..." >> $LOG_FILE
while read -r url; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 拉取: $url" >> $LOG_FILE
    curl -sL --connect-timeout $CONNECT_TIMEOUT "$url" >> $TEMP_M3U 2>> $LOG_FILE
done < $SOURCE_FILE
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 信源拉取完成" >> $LOG_FILE

# 2. 验证并筛选源
declare -A channel_map
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 筛选规则: 480p/720p/1080p + 200Kbps" >> $LOG_FILE

while IFS= read -r line; do
    if [[ "$line" =~ ^#EXTINF ]]; then
        channel_info=$line
        channel_name=$(echo "$channel_info" | awk -F ',' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')
        read -r play_url || continue
        play_url=$(echo "$play_url" | sed 's/^[ \t]*//;s/[ \t]*$//')
        [[ -z "$play_url" || "$play_url" =~ ^# ]] && continue

        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 验证: $channel_name" >> $LOG_FILE
        # 使用ffmpeg验证流
        ffprobe -v error -timeout ${CONNECT_TIMEOUT}000000 -i "$play_url" -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 2>/dev/null || true
        bitrate=$(ffprobe -v error -timeout ${CONNECT_TIMEOUT}000000 -i "$play_url" -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 2>/dev/null || echo 0)
        codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$play_url" 2>/dev/null || echo "")
        width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$play_url" 2>/dev/null || echo 0)

        res="480p"
        [[ $width -ge 1280 && $width -lt 1920 ]] && res="720p"
        [[ $width -ge 1920 ]] && res="1080p"

        # 验证是否符合规则（已大幅放宽）
        if [[ " ${SUPPORT_RESOLUTIONS[@]} " =~ " $res " && $bitrate -ge $MIN_BITRATE && ( " ${SUPPORT_CODECS[@]} " =~ " $codec " || -z "$codec" ) ]]; then
            group="其他"
            for rule in "${GROUP_RULES[@]}"; do
                group_name=$(echo "$rule" | awk -F ':' '{print $1}')
                keywords=$(echo "$rule" | awk -F ':' '{print $2}')
                [[ "$channel_name" =~ $keywords ]] && group=$group_name; break;
            done

            key="$channel_name|$res"
            if [[ -z "${channel_map[$key]}" ]]; then
                channel_map[$key]="$channel_info|$play_url|$bitrate|$group|$res"
            else
                existing_bitrate=$(echo "${channel_map[$key]}" | awk -F '|' '{print $3}')
                [[ $bitrate -gt $existing_bitrate ]] && channel_map[$key]="$channel_info|$play_url|$bitrate|$group|$res"
            fi
        fi
    fi
done < $TEMP_M3U

# 3. 生成最终播放列表
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 生成最终列表，有效频道数: ${#channel_map[@]}" >> $LOG_FILE
echo "#EXTM3U" > $FINAL_M3U

for channel_data in "${channel_map[@]}"; do
    channel_info=$(echo "$channel_data" | awk -F '|' '{print $1}')
    play_url=$(echo "$channel_data" | awk -F '|' '{print $2}')
    group=$(echo "$channel_data" | awk -F '|' '{print $4}')
    res=$(echo "$channel_data" | awk -F '|' '{print $5}')

    new_info=$(echo "$channel_info" | sed "s/^#EXTINF:/& group-title=\"$group\" res=\"$res\" /")
    echo "$new_info" >> $FINAL_M3U
    echo "$play_url" >> $FINAL_M3U
done

# 清理临时文件
rm -f $TEMP_M3U

echo "[$(date +'%Y-%m-%d %H:%M:%S')] 流程完成！" >> $LOG_FILE
echo "  最终列表: $FINAL_M3U" >> $LOG_FILE
echo "  验证日志: $LOG_FILE" >> $LOG_FILE
echo "  有效频道数: ${#channel_map[@]}" >> $LOG_FILE
