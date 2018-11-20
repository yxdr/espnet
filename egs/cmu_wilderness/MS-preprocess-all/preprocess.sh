#!/bin/bash

# Copyright 2018 Johns Hopkins University (Matthew Wiesner)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)


. ./path.sh
. ./cmd.sh

# Training options
backend=pytorch
stage=0
ngpu=0
debugmode=1
dumpdir=dump
N=0
verbose=0
resume=
seed=1
batchsize=20
maxlen_in=800
maxlen_out=150
epochs=15
tag=""
adapt_langs_fn=""

# Feature options
do_delta=false

# Encoder
etype=vggblstmp
elayers=4
eunits=768
eprojs=768
subsample=1_2_2_1_1

# Attention 
atype=location
adim=768
awin=5
aheads=4
aconv_chans=10
aconv_filts=100

# Decoder
dlayers=1
dunits=768

# Objective
mtlalpha=0.5
lsm_type=unigram
lsm_weight=0.05
samp_prob=0.0

# Optimizer
opt=adadelta

# Decoding
beam_size=20
nbest=1
penalty=0.0
maxlenratio=0.0
minlenratio=0.0
ctc_weight=0.3
recog_model=model.acc.best # set a model to be used for decoding: 'model.acc.best' or 'model.loss.best'
use_lm=false
decode_nj=32

. ./utils/parse_options.sh || exit 1;

datasets=/export/b15/oadams/datasets-CMU_Wilderness

all_eval_langs_fn=conf/langs/eval_langs
eval_readings_fn=conf/langs/eval_readings

train_langs="aymara-notgt aymara indonesian-notgt indonesian"
train_langs_fns=""
for l in ${train_langs}; do
    train_langs_fns="conf/langs/${l} ${train_langs_fns}"
done

train_set="${train_langs}_train"
train_dev="${dev_langs}_dev"
recog_set="${eval_langs}_eval"
all_eval_langs_train="${all_eval_langs}_train"
adapt_langs_train="${adapt_langs}_train"
adapt_langs_dev="${adapt_langs}_train"
adapt_langs_eval="${adapt_langs}_train"

if [ $stage -le 0 ]; then

    # Preparing audio data for each evaluation language and train/dev/test
    # splits for monolingual training
    for reading in `cat ${all_eval_langs_fn} | tr "\n" " "`; do
        echo $reading
        reading_fn="conf/langs/${reading}"
        ./local/prepare_audio_data.sh --langs ${reading_fn} ${datasets}
        ./local/create_splits.sh data/local ${reading_fn} ${reading_fn} ${reading_fn} 
    done

    # Preparing data for each language (a group of readings).
    for train_lang_fn in ${train_langs_fns}; do
        echo $train_lang_fn
        ./local/prepare_audio_data.sh --langs ${train_lang_fn} ${datasets}
        ./local/create_splits.sh data/local ${train_lang_fn} ${train_lang_fn} ${train_lang_fn} 
    done

    # Prepare data for all possible evaluation readings that a seed model might
    # get adapted to, so that we can have in advance a dictionary that covers
    # all the languages' graphemes.
    ./local/prepare_audio_data.sh --langs ${eval_readings_fn} ${datasets}
    ./local/create_splits.sh data/local ${eval_readings_fn} ${eval_readings_fn} ${eval_readings_fn}
fi

if [ ${stage} -le 1 ]; then
    echo "stage 1: Feature Generation"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame

    # Prepare training data; includes CMVN stats.
    for train_set_path in data/*_train; do
        train_set=`basename ${train_set_path}`
        echo $train_set
        feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
        steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 50 --write_utt2num_frames true \
            train/${train_set} exp/make_fbank/${train_set} ${fbankdir}
        # compute global CMVN
        compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark
        exp_name=`basename $PWD`
        # dump features for training
        if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
        utils/create_split_dir.pl \
            /export/b{10,11,12,13}/${USER}/espnet-data/egs/cmu_wilderness/${exp_name}/dump/${train_set}/delta${do_delta}/storage \
            ${feat_tr_dir}/storage
        fi
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
            data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/train ${feat_tr_dir}
    done

    # Prepare dev data;
    exit
    feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
    feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}

        for x in ${train_set} ${train_dev} ${recog_set}; do
            steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 50 --write_utt2num_frames true \
                data/${x} exp/make_fbank/${x} ${fbankdir}
        done

        # compute global CMVN
        compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark

        exp_name=`basename $PWD`
        # dump features for training
        if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
        utils/create_split_dir.pl \
            /export/b{10,11,12,13}/${USER}/espnet-data/egs/cmu_wilderness/${exp_name}/dump/${train_set}/delta${do_delta}/storage \
            ${feat_tr_dir}/storage
        fi
        if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_dt_dir}/storage ]; then
        utils/create_split_dir.pl \
            /export/b{10,11,12,13}/${USER}/espnet-data/egs/cmu_wilderness/${exp_name}/dump/${train_dev}/delta${do_delta}/storage \
            ${feat_dt_dir}/storage
        fi
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
            data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/train ${feat_tr_dir}
        dump.sh --cmd "$train_cmd" --nj 4 --do_delta $do_delta \
            data/${train_dev}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/dev ${feat_dt_dir}

        for rtask in ${recog_set}; do
            feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}; mkdir -p ${feat_recog_dir}
            dump.sh --cmd "$train_cmd" --nj 4 --do_delta $do_delta \
                data/${rtask}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/recog/${rtask} \
                ${feat_recog_dir}
        done
    fi
    exit
fi


dict=data/lang_1char/${train_set}_units.txt
nlsyms=data/lang_1char/non_lang_syms.txt

echo "dictionary: ${dict}"
if [ ${stage} -le 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1char/

    echo "make a non-linguistic symbol list"
    cat data/${train_set}/text data/${all_eval_langs_train}/text | cut -f 2- | tr " " "\n" | sort | uniq | grep "<" > ${nlsyms}
    cat ${nlsyms}

    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    cat data/${train_set}/text data/${all_eval_langs_train}/text | text2token.py -s 1 -n 1 | cut -f 2- -d" " | tr " " "\n" \
    | sort | uniq | grep -v -e '^\s*$' | awk '{print $0 " " NR+1}' >> ${dict}
    wc -l ${dict}

    echo "hello"

    # make json labels
    for rtask in ${train_set} ${train_dev} ${recog_set} ${adapt_langs_train} ${adapt_langs_dev} ${adapt_langs_eval}; do
        echo $rtask
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
        mkjson.py --non-lang-syms ${nlsyms} ${feat_recog_dir}/feats.scp data/${rtask} ${dict} > ${feat_recog_dir}/data.json
    done
    exit
fi

if [ -z ${tag} ]; then
    expdir=exp/${train_set}_${backend}_${etype}_e${elayers}_subsample${subsample}_unit${eunits}_proj${eprojs}_d${dlayers}_unit${dunits}_${atype}_aconvc${aconv_chans}_aconvf${aconv_filts}_mtlalpha${mtlalpha}_${opt}_sampprob${samp_prob}_bs${batchsize}_mli${maxlen_in}_mlo${maxlen_out}
    if ${do_delta}; then
        expdir=${expdir}_delta
    fi
else
    expdir=exp/${train_set}_${backend}_${tag}
fi
mkdir -p ${expdir}

if [ ${stage} -le 3 ]; then
    echo "stage 3: Network Training"

    if [[ ${adapt_langs_fn} ]]; then
        resume_expdir=$expdir
        expdir="${expdir}_adapt-`basename ${adapt_langs_fn}`"
        resume="${resume_expdir}/results/snapshot.ep.15"
        echo "Resuming model from ${resume}"
        echo "$expdir"
    fi

    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        asr_train.py \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --outdir ${expdir}/results \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --verbose ${verbose} \
        --resume ${resume} \
        --no_restore_trainer \
        --train-json ${feat_tr_dir}/data.json \
        --valid-json ${feat_dt_dir}/data.json \
        --etype ${etype} \
        --elayers ${elayers} \
        --eunits ${eunits} \
        --eprojs ${eprojs} \
        --subsample ${subsample} \
        --dlayers ${dlayers} \
        --dunits ${dunits} \
        --atype ${atype} \
        --adim ${adim} \
        --aconv-chans ${aconv_chans} \
        --aconv-filts ${aconv_filts} \
        --mtlalpha ${mtlalpha} \
        --batch-size ${batchsize} \
        --maxlen-in ${maxlen_in} \
        --maxlen-out ${maxlen_out} \
        --sampling-probability ${samp_prob} \
        --opt ${opt} \
        --epochs ${epochs}
    exit
fi

if [ ${stage} -le 4 ]; then

    echo "stage 4: Decoding"

    extra_opts=""
    if $use_lm; then
      extra_opts="--word-rnnlm ${lmexpdir}/rnnlm.model.best --lm-weight ${lm_weight} ${extra_opts}"
    fi

    for rtask in ${recog_set}; do
    (
        decode_dir=decode_${rtask}_beam${beam_size}_e${recog_model}_p${penalty}_len${minlenratio}-${maxlenratio}_ctcw${ctc_weight}
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}

        # split data
        splitjson.py --parts ${decode_nj} ${feat_recog_dir}/data.json 

        #### use CPU for decoding
        ngpu=0

        ${decode_cmd} JOB=1:${decode_nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            asr_recog.py \
            --ngpu ${ngpu} \
            --backend ${backend} \
            --recog-json ${feat_recog_dir}/split${decode_nj}utt/data.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results/${recog_model}  \
            --model-conf ${expdir}/results/model.json \
            --beam-size ${beam_size} \
            --penalty ${penalty} \
            --ctc-weight ${ctc_weight} \
            --maxlenratio ${maxlenratio} \
            --minlenratio ${minlenratio} \
            ${extra_opts} &
        wait

        score_sclite.sh --wer true ${expdir}/${decode_dir} ${dict} grapheme[1]

    ) &
    done
    wait
    echo "Finished"
fi
