#!/bin/bash
source test_tipc/common_func.sh

# set env
python=python
export model_branch=`git symbolic-ref HEAD 2>/dev/null | cut -d"/" -f 3`
export model_commit=$(git log|head -n1|awk '{print $2}')
export str_tmp=$(echo `pip list|grep paddlepaddle-gpu|awk -F ' ' '{print $2}'`)
export frame_version=${str_tmp%%.post*}
export frame_commit=$(echo `${python} -c "import paddle;print(paddle.version.commit)"`)

# BENCHMARK_ROOT='.'  # only for self-test

# run benchmark sh
# Usage:
# bash run_benchmark_train.sh config.txt params
# or
# bash run_benchmark_train.sh config.txt

function func_parser_params(){
    strs=$1
    IFS="="
    array=(${strs})
    tmp=${array[1]}
    echo ${tmp}
}

function func_sed_params(){
    filename=$1
    line=$2
    param_value=$3
    params=`sed -n "${line}p" $filename`
    IFS=":"
    array=(${params})
    key=${array[0]}
    value=${array[1]}
    if [[ $value =~ 'benchmark_train' ]];then
        IFS='='
        _val=(${value})
        param_value="${param_value}"
    fi
    new_params="${key}:${param_value}"
    IFS=";"
    cmd="sed -i '${line}s/.*/${new_params}/' '${filename}'"
    eval $cmd
}

function set_gpu_id(){
    string=$1
    _str=${string:1:6}
    IFS="C"
    arr=(${_str})
    M=${arr[0]}
    P=${arr[1]}
    gn=`expr $P - 1`
    gpu_num=`expr $gn / $M`
    seq=`seq -s "," 0 $gpu_num`
    echo $seq
}

function get_repo_name(){
    IFS=";"
    cur_dir=$(pwd)
    IFS="/"
    arr=(${cur_dir})
    echo ${arr[-1]}
}

FILENAME=$1
# copy FILENAME as new
new_filename="./test_tipc/benchmark_train.txt"
cmd=`yes|cp $FILENAME $new_filename`
FILENAME=$new_filename
# MODE must be one of ['benchmark_train']
MODE=$2
PARAMS=$3
REST_ARGS=$4
# bash test_tipc/benchmark_train.sh /workspace/PaddleVideo/test_tipc/configs/BMN/train_infer_python.txt benchmark_train to_static

to_static="d2sF"
# parse "to_static" options and modify trainer into "to_static_trainer"
if [ $REST_ARGS = "to_static" ] || [ $PARAMS = "to_static" ] ;then
   to_static="d2sT"
   sed -i 's/trainer:norm_train/trainer:to_static_train/g' $FILENAME
   # clear PARAM contents
   if [ $PARAMS = "to_static" ] ;then
    PARAMS=""
   fi
fi

IFS=$'\n'
# parser params from train_benchmark.txt
dataline=`cat $FILENAME`
# parser params
IFS=$'\n'
lines=(${dataline})
model_name=$(func_parser_value "${lines[1]}")

# 获取'train_benchmark_params'所在的行数
line_num=`grep -n "train_benchmark_params" $FILENAME  | cut -d ":" -f 1`
# for train log parser
batch_size=$(func_parser_value "${lines[line_num]}")
line_num=`expr $line_num + 1`
fp_items=$(func_parser_value "${lines[line_num]}")
line_num=`expr $line_num + 1`
epoch=$(func_parser_value "${lines[line_num]}")

line_num=`expr $line_num + 1`
profile_option_key=$(func_parser_key "${lines[line_num]}")
profile_option_params=$(func_parser_value "${lines[line_num]}")
profile_option="${profile_option_key}:${profile_option_params}"

line_num=`expr $line_num + 1`
flags_value=$(func_parser_value "${lines[line_num]}")

# 设置每个模型max-iters，以获取稳定的ips
line_num=`expr $line_num + 1`
max_iters_value=$(func_parser_value "${lines[line_num]}")

# set flags
IFS=";"
flags_list=(${flags_value})
for _flag in ${flags_list[*]}; do
    cmd="export ${_flag}"
    eval $cmd
done

# set log_name
repo_name=$(get_repo_name )
SAVE_LOG=${BENCHMARK_LOG_DIR:-$(pwd)}   # */benchmark_log
mkdir -p "${SAVE_LOG}/benchmark_log/"
status_log="${SAVE_LOG}/benchmark_log/results.log"

# The number of lines in which train params can be replaced.
line_python=3
line_gpuid=4
line_precision=6
line_epoch=7
line_batchsize=9
line_profile=12
line_eval_py=24
line_eval_py_2=25
line_export_py=38
line_export_py_2=28
line_export_py_3=30
line_norm_train=16

func_sed_params "$FILENAME" "${line_eval_py}" "null"
func_sed_params "$FILENAME" "${line_eval_py_2}" "null"
func_sed_params "$FILENAME" "${line_export_py}" "null"
func_sed_params "$FILENAME" "${line_export_py_2}" "null"
func_sed_params "$FILENAME" "${line_export_py_3}" "null"
func_sed_params "$FILENAME" "${line_python}"  "$python"


# 末尾加上--max_iters=30和--log_interval=1，以便运行并输出足量数据
set_log_interval_cmd="sed -i '${line_norm_train}s/.*/& --max_iters=${max_iters_value} -o log_interval=1/' '${filename}'"
eval $set_log_interval_cmd

# 去掉--validate，benchmark不需要validate
remove_validate_cmd="sed -i '${line_norm_train}s/--validate//' '${filename}'"
eval $remove_validate_cmd

# if params
if  [ ! -n "$PARAMS" ] ;then
    # PARAMS input is not a word.
    IFS="|"
    batch_size_list=(${batch_size})
    fp_items_list=(${fp_items})
    device_num_list=(N1C4)
    run_mode="DP"
else
    # parser params from input: modeltype_bs${bs_item}_${fp_item}_${run_mode}_${device_num}
    IFS="_"
    params_list=(${PARAMS})
    model_type=${params_list[0]}
    batch_size=${params_list[1]}
    batch_size=`echo  ${batch_size} | tr -cd "[0-9]" `
    precision=${params_list[2]}
    run_mode=${params_list[3]}
    device_num=${params_list[4]}
    IFS=";"

    if [ ${precision} = "null" ];then
        precision="fp32"
    fi

    fp_items_list=($precision)
    batch_size_list=($batch_size)
    device_num_list=($device_num)
fi

log_interval='--log_interval 1'
IFS="|"
for batch_size in ${batch_size_list[*]}; do
    for precision in ${fp_items_list[*]}; do
        for device_num in ${device_num_list[*]}; do
            # sed batchsize and precision
            func_sed_params "$FILENAME" "${line_precision}" "$precision"
            func_sed_params "$FILENAME" "${line_batchsize}" "$batch_size"
            func_sed_params "$FILENAME" "${line_epoch}" "$epoch"
            gpu_id=$(set_gpu_id $device_num)

            if [ ${#gpu_id} -le 1 ];then
                log_path="$SAVE_LOG/profiling_log"
                mkdir -p $log_path
                log_name="${repo_name}_${model_name}_bs${batch_size}_${precision}_${run_mode}_${device_num}_${to_static}_profiling"
                func_sed_params "$FILENAME" "${line_gpuid}" "0"  # sed used gpu_id
                # set profile_option params
                tmp=`sed -i "${line_profile}s/.*/${profile_option}/" "${FILENAME}"`

                # for models which need to accumulate gradient.
                if [[ ${model_name} =~ "TimeSformer" ]]; then
                    global_bs=`expr ${batch_size} \* ${device_num:3:4} \* 8`
                    modify_global_bs_cmd="sed -i '${line_norm_train}s/.*/& -o GRADIENT_ACCUMULATION.global_batch_size=${global_bs}/' '${filename}'"
                    eval $modify_global_bs_cmd
                fi

                # run test_train_inference_python.sh
                cmd="bash test_tipc/test_train_inference_python.sh ${FILENAME} benchmark_train > ${log_path}/${log_name} 2>&1 "
                echo $cmd
                eval $cmd
                eval "cat ${log_path}/${log_name}"

                # without profile
                log_path="$SAVE_LOG/train_log"
                speed_log_path="$SAVE_LOG/index"
                mkdir -p $log_path
                mkdir -p $speed_log_path
                log_name="${repo_name}_${model_name}_bs${batch_size}_${precision}_${run_mode}_${device_num}_${to_static}_log"
                speed_log_name="${repo_name}_${model_name}_bs${batch_size}_${precision}_${run_mode}_${device_num}_${to_static}_speed"
                func_sed_params "$FILENAME" "${line_profile}" "null"  # sed profile_id as null

                cmd="bash test_tipc/test_train_inference_python.sh ${FILENAME} benchmark_train > ${log_path}/${log_name} 2>&1 "
                echo $cmd
                job_bt=`date '+%Y%m%d%H%M%S'`
                eval $cmd
                job_et=`date '+%Y%m%d%H%M%S'`
                export model_run_time=$((${job_et}-${job_bt}))
                eval "cat ${log_path}/${log_name}"

                # parser log
                _model_name="${model_name}_bs${batch_size}_${precision}_${run_mode}"
                cmd="${python} ${BENCHMARK_ROOT}/scripts/analysis.py --filename ${log_path}/${log_name} \
                        --speed_log_file '${speed_log_path}/${speed_log_name}' \
                        --model_name ${_model_name} \
                        --base_batch_size ${batch_size} \
                        --run_mode ${run_mode} \
                        --fp_item ${precision} \
                        --keyword ips: \
                        --skip_steps 5 \
                        --device_num ${device_num} \
                        --speed_unit instance/sec \
                        --convergence_key loss: "
                echo $cmd
                eval $cmd
                last_status=${PIPESTATUS[0]}
                status_check $last_status "${cmd}" "${status_log}" "${model_name}"
            else
                IFS=";"
                unset_env=`unset CUDA_VISIBLE_DEVICES`
                log_path="$SAVE_LOG/train_log"
                speed_log_path="$SAVE_LOG/index"
                mkdir -p $log_path
                mkdir -p $speed_log_path
                log_name="${repo_name}_${model_name}_bs${batch_size}_${precision}_${run_mode}_${device_num}_${to_static}_log"
                speed_log_name="${repo_name}_${model_name}_bs${batch_size}_${precision}_${run_mode}_${device_num}_${to_static}_speed"
                func_sed_params "$FILENAME" "${line_gpuid}" "$gpu_id"  # sed used gpu_id
                func_sed_params "$FILENAME" "${line_profile}" "null"  # sed --profile_option as null

                # for models which need to accumulate gradient.
                if [[ ${model_name} =~ "TimeSformer" ]]; then
                    global_bs=`expr ${batch_size} \* ${device_num:3:4} \* 8`
                    modify_global_bs_cmd="sed -i '${line_norm_train}s/.*/& -o GRADIENT_ACCUMULATION.global_batch_size=${global_bs}/' '${filename}'"
                    eval $modify_global_bs_cmd
                fi

                cmd="bash test_tipc/test_train_inference_python.sh ${FILENAME} benchmark_train > ${log_path}/${log_name} 2>&1 "
                echo $cmd
                job_bt=`date '+%Y%m%d%H%M%S'`
                eval $cmd
                job_et=`date '+%Y%m%d%H%M%S'`
                export model_run_time=$((${job_et}-${job_bt}))
                eval "cat ${log_path}/${log_name}"
                # parser log
                _model_name="${model_name}_bs${batch_size}_${precision}_${run_mode}"
                cmd="${python} ${BENCHMARK_ROOT}/scripts/analysis.py --filename ${log_path}/${log_name} \
                        --speed_log_file '${speed_log_path}/${speed_log_name}' \
                        --model_name ${_model_name} \
                        --base_batch_size ${batch_size} \
                        --run_mode ${run_mode} \
                        --fp_item ${precision} \
                        --keyword ips: \
                        --skip_steps 5 \
                        --device_num ${device_num} \
                        --speed_unit instance/sec \
                        --convergence_key loss: "
                echo $cmd
                eval $cmd
                last_status=${PIPESTATUS[0]}
                status_check $last_status "${cmd}" "${status_log}" "${model_name}"
            fi
        done
    done
done
