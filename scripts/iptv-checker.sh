#!/bin/bash
# GitHub IPTV自动化脚本
SOURCE_FILE="./sources/public-sources.txt"
TEMP_M3U="./dist/iptv-temp.m3u"
FINAL_M3U="./dist/iptv-valid.m3u"
LOG_FILE="./dist/iptv-verify.log"
CONNECT_TIMEOUT=3
STREAM_TIMEOUT=8
MIN_BITRATE=500000
SUPPORT_CODECS=("h264" "hevc" "mpeg4")
SUPPORT_RESOLUTIONS=("720p" "1080p")
GROUP_RULES=(
  "央视:CCTV|中央电视台|央视频|央视综合|央视财经"
  "卫视:卫视|湖南卫视|浙江卫视|江苏卫视|东方卫视|北京卫视|广东卫视|山东卫视|河南卫视"
  "地方台:北京|上海|广东|深圳|江苏|浙江|山东|四川|重庆|天津|湖北|湖南|河南|河北|福建|安徽"
  "影视:电影|剧场|影视|影院|综艺|卫视剧场|央视剧场"
  "新闻:新闻|资讯|财经|法治|国际|民生|早间新闻|晚间新闻"
  "体育:体育|CCTV5|赛事|奥运|足球|篮球|英超|NBA|中超"
  "海外:香港|台湾|澳门|TVB|凤凰|翡翠|明珠|华娱|星空"
  "少儿:少儿|卡通|动漫|宝贝|早教|金鹰卡通|央视少儿"
  "戏曲:戏曲|京剧|越剧|黄梅戏|豫剧|昆曲|秦腔|梨园"
)

mkdir -p ./dist
> $TEMP_M3U
> $FINAL_M3U
> $LOG_FILE
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 启动GitHub IPTV自动验证流程" >> $LOG_FILE

echo "#EXTM3U" > $TEMP_M3U
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 拉取公开IPTV信源..." >> $LOG_FILE
while read -r url; do
  [[ -z "$url" || "$url" == \#* ]] && continue
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] 拉取：$url" >> $LOG_FILE
  curl -sL --connect-timeout $CONNECT_TIMEOUT "$url" >> $TEMP_M3U 2>> $LOG_FILE
  echo -e "\n" >> $TEMP_M3U
done < $SOURCE_FILE
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 信源拉取完成" >> $LOG_FILE

echo "#EXTM3U" > $FINAL_M3U
declare -A channel_map

echo "[$(date +'%Y-%m-%d %H:%M:%S')] 筛选规则：720P/1080P + ≥500kbps" >> $LOG_FILE
while IFS= read -r line; do
  if [[ $line == \#EXTINF* ]]; then
    channel_info=$line
    channel_name=$(echo "$channel_info" | awk -F ',' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    read -r play_url || continue
    play_url=$(echo "$play_url" | sed 's/^[ \t]*//;s/[ \t]*$//')
    [[ -z "$play_url" || "$play_url" == \#* ]] && continue

    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 验证：$channel_name" >> $LOG_FILE
    
    ffmpeg -v error -timeout $(($CONNECT_TIMEOUT * 1000000)) -i "$play_url" -t $STREAM_TIMEOUT -f null /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$play_url" 2>/dev/null || echo $(($MIN_BITRATE + 100000)))
      codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$play_url" 2>/dev/null | tr 'A-Z' 'a-z')
      width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$play_url" 2>/dev/null || echo 0)
      
      res="480p"
      [[ $width -ge 1280 && $width -lt 1920 ]] && res="720p"
      [[ $width -ge 1920 ]] && res="1080p"
      
      if [[ " ${SUPPORT_RESOLUTIONS[*]} " =~ " $res " && $bitrate -ge $MIN_BITRATE && " ${SUPPORT_CODECS[*]} " =~ " $codec " ]]; then
        group="其他"
        for rule in "${GROUP_RULES[@]}"; do
          group_name=$(echo "$rule" | awk -F ':' '{print $1}')
          keywords=$(echo "$rule" | awk -F ':' '{print $2}')
          [[ "$channel_name" =~ $keywords ]] && { group=$group_name; break; }
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
  fi
done < $TEMP_M3U

echo "[$(date +'%Y-%m-%d %H:%M:%S')] 生成最终列表，有效频道数：${#channel_map[@]}" >> $LOG_FILE
for channel_data in "${channel_map[@]}"; do
  channel_info=$(echo "$channel_data" | awk -F '|' '{print $1}')
  play_url=$(echo "$channel_data" | awk -F '|' '{print $2}')
  group=$(echo "$channel_data" | awk -F '|' '{print $4}')
  res=$(echo "$channel_data" | awk -F '|' '{print $5}')
  
  new_info=$(echo "$channel_info" | sed "s/^#EXTINF:/& group-title=\"$group\" res=\"$res\" /")
  echo "$new_info" >> $FINAL_M3U
  echo "$play_url" >> $FINAL_M3U
done

rm -f $TEMP_M3U
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 流程完成！" >> $LOG_FILE
echo "  最终列表：$FINAL_M3U" >> $LOG_FILE
echo "  验证日志：$LOG_FILE" >> $LOG_FILE
echo "  有效频道数：${#channel_map[@]}" >> $LOG_FILE
