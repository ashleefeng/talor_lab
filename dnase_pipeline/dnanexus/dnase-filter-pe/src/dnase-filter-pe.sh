#!/bin/bash
# dnase-filter-pe.sh - Merge and filter bams (paired-end) for the ENCODE DNase-seq pipeline.

main() {
    echo "Installing picard tools and pysam..."
    set -x
    wget https://github.com/broadinstitute/picard/releases/download/2.8.1/picard.jar > install.log 2>&1
    tail -2 install.log
    #sudo pip install -I pysam==0.9.0 >> install.log 2>&1
    #tail -2 install.log
    mv /usr/bin/filter_reads.py .
    set +x
    # executables in resources/usr/bin

    # If available, will print tool versions to stderr and json string to stdout
    versions=''
    if [ -f /usr/bin/tool_versions.py ]; then
        versions=`tool_versions.py --dxjson dnanexus-executable.json`
    fi

    echo "* Value of bam_set:    '$bam_set'"
    echo "* Value of map_thresh: '$map_thresh'"
    echo "* Value of UMI:        '$umi'"
    echo "* Value of nthreads:   '$nthreads'"

    merged_bam_root=""
    merged=""
    tech_reps=""
    found_umi=""
    rm -f concat.fq
    for ix in ${!bam_set[@]}
    do
        file_root=`dx describe "${bam_set[$ix]}" --name`
        file_root=${file_root%.bam}
        file_root=${file_root%_techrep}
        file_root=${file_root%_bwa}
        sans_se=${file_root%_se}
        if [ "${sans_se}" != "${file_root}" ]; then
            echo "ERROR: Single-ended alignment file is not supported in paired-end filtering."
            exit 1
        fi
        file_root=${file_root%_pe}
        if [ "${merged_bam_root}" == "" ]; then
            merged_bam_root="${file_root}_pe_bwa_biorep"
        else
            merged_bam_root="${file_root}_${merged_bam_root}"
            if [ "${merged}" == "" ]; then
                merged="s merged as"
            fi
        fi
        if [ -f /usr/bin/parse_property.py ]; then
            bam_umi=`parse_property.py -f "'${bam_set[$ix]}'" -p "UMI" --quiet`
            if [ "$bam_umi" != "yes" ]; then
                bam_umi="no"
            fi
            if [ "$found_umi" != "" ] && [ "$found_umi" != "$bam_umi" ]; then
                echo "ERROR: bams must all have the same UMI state."
                exit 1
            fi
            found_umi=$bam_umi
            if [ "$exp_id" == "" ]; then
                exp_id=`parse_property.py -f "'${bam_set[$ix]}'" --project "${DX_PROJECT_CONTEXT_ID}" --exp_id`
            fi
            rep_tech=`parse_property.py -f "'${bam_set[$ix]}'" --project "${DX_PROJECT_CONTEXT_ID}" --rep_tech`
            if [ "$rep_tech" != "" ]; then
                if  [ "$tech_reps" != "" ]; then
                    tech_reps="${tech_reps}_${rep_tech}"
                else
                    tech_reps="${rep_tech}"
                fi
            fi
        fi
        echo "* Downloading ${file_root}_bwa.bam file..."
        dx download "${bam_set[$ix]}" -o ${file_root}_bwa.bam
        if [ ! -e sofar.bam ]; then
            mv ${file_root}_bwa.bam sofar.bam
        else
            echo "* Merging..."
            # cat is faster than merge and samtools sort -n is first step of actual processing
            set -x
            samtools cat sofar.bam ${file_root}_bwa.bam > merging.bam
            mv merging.bam sofar.bam
            set +x
        fi
    done
    if [ "$exp_id" != "" ] && [ "$tech_reps" != "" ]; then
        merged_bam_root="${exp_id}_${tech_reps}_pe_bwa_biorep"
    fi
    echo "* Merged alignments file will be: '${merged_bam_root}.bam'"

    # Discovering UMI state
    if [ "$found_umi" != "" ]; then
        if [ "$umi" != "yes" ] && [ "$umi" != "no" ]; then
            echo "* UMI state discovered to be '$found_umi'."
            umi=$found_umi
        elif [ "$found_umi" == "$umi" ]; then
            echo "* UMI state confirmed to be '$found_umi'."
        else
            echo "* UMI state discovered to be '$found_umi' but running as requested: UMI='$umi'."
        fi
    elif [ "$umi" == "discover" ]; then
        echo "ERROR: UMI state could not be discovered and must be set."
        exit 1
    fi
    if [ "$umi" != "yes" ] && [ "$umi" != "no" ]; then
        echo "ERROR: UMI state must be either 'yes' or 'no'."
        exit 1
    fi

    # At this point there is a 'sofar.bam' with one or more input bams
    if [ "${merged}" == "" ]; then
        echo "* Only one input file, no merging required."
    else
        # Sort not necessary for filtering and merged bam is not saved
        #echo "* Sorting merged bam..."
        #set -x
        #samtools sort -@ $nthreads -m 6G -f sofar.bam sorted.bam
        #samtools view -hb sorted.bam > sofar.bam
        #set +x
        echo "* Files merging into '${merged_bam_root}.bam'"
    fi
    set -x
    mv sofar.bam ${merged_bam_root}.bam
    set +x

    echo "* ===== Calling DNAnexus and ENCODE independent script... ====="
    filtered_bam_root="${merged_bam_root}_filtered"
    # TEMPORARY
    marked_bam_root="${merged_bam_root}_marked"
    # TEMPORARY
    set -x
    dnase_filter_pe.sh ${merged_bam_root}.bam $map_thresh $nthreads $umi "$filtered_bam_root"
    set +x
    echo "* ===== Returned from dnanexus and encodeD independent script ====="

    echo "* Prepare metadata for filtered bam..."
    qc_filtered=''
    prefiltered_all_reads=0
    prefiltered_mapped_reads=0
    filtered_mapped_reads=0
    read_len=0
    if [ -f /usr/bin/qc_metrics.py ]; then
        qc_filtered=`qc_metrics.py -n samtools_flagstats -f ${filtered_bam_root}_flagstat.txt`
        prefiltered_all_reads=`qc_metrics.py -n samtools_flagstats -f ${merged_bam_root}_flagstat.txt -k total`
        prefiltered_mapped_reads=`qc_metrics.py -n samtools_flagstats -f ${merged_bam_root}_flagstat.txt -k mapped`
        filtered_all_reads=`qc_metrics.py -n samtools_flagstats -f ${filtered_bam_root}_flagstat.txt -k total`
        filtered_mapped_reads=`qc_metrics.py -n samtools_flagstats -f ${filtered_bam_root}_flagstat.txt -k mapped`
        read_len=`qc_metrics.py -n samtools_stats -d ':' -f ${filtered_bam_root}_samstats_summary.txt -k "average length"`
        meta=`qc_metrics.py -n samtools_stats -d ':' -f ${filtered_bam_root}_samstats_summary.txt`
        qc_filtered=`echo $qc_filtered, $meta`
        grep -i Library ${filtered_bam_root}_dup_qc.txt > ${filtered_bam_root}_dup_summary.txt
        meta=`qc_metrics.py -n dup_stats -f ${filtered_bam_root}_dup_summary.txt`
        qc_filtered=`echo $qc_filtered, $meta`
        qc_filtering=`echo \"pre-filter all reads\": $prefiltered_all_reads`
        qc_filtering=`echo $qc_filtering, \"pre-filter mapped reads\": $prefiltered_mapped_reads`
        qc_filtering=`echo $qc_filtering, \"post-filter all reads\": $filtered_all_reads`
        qc_filtering=`echo $qc_filtering, \"post-filter mapped reads\": $filtered_mapped_reads`
        qc_filtered=`echo $qc_filtered, \"filtering\": { $qc_filtering }`
    fi
    # All qc to one file per target file:
    echo "===== samtools flagstat ====="   > ${filtered_bam_root}_qc.txt
    cat ${filtered_bam_root}_flagstat.txt >> ${filtered_bam_root}_qc.txt
    echo " "                                 >> ${filtered_bam_root}_qc.txt
    if [ "$umi" == "yes" ]; then
        echo "===== picard UmiAwareMarkDuplicatesWithMateCigar =====" >> ${filtered_bam_root}_qc.txt
    else
        echo "===== picard MarkDuplicatesWithMateCigar =====" >> ${filtered_bam_root}_qc.txt
    fi
    cat ${filtered_bam_root}_dup_qc.txt      >> ${filtered_bam_root}_qc.txt
    echo " "                              >> ${filtered_bam_root}_qc.txt
    echo "===== samtools stats ====="     >> ${filtered_bam_root}_qc.txt
    cat ${filtered_bam_root}_samstats.txt >> ${filtered_bam_root}_qc.txt

    echo "* Upload results..."
    bam_filtered=$(dx upload ${filtered_bam_root}.bam --details "{ $qc_filtered }" --property SW="$versions" \
                                      --property prefiltered_all_reads="$prefiltered_all_reads" --property pe_or_se="pe" \
                                      --property prefiltered_mapped_reads="$prefiltered_mapped_reads" \
                                      --property filtered_mapped_reads="$filtered_mapped_reads" \
                                      --property read_length="$read_len" --property from_UMI="$umi" --brief)
    bam_filtered_qc=$(dx upload ${filtered_bam_root}_qc.txt --details "{ $qc_filtered }" --property from_UMI="$umi" --property SW="$versions" --brief)
    # TEMPORARY
    bam_marked=$(dx upload ${marked_bam_root}.bam --property SW="$versions" --brief)
    # TEMPORARY

    dx-jobutil-add-output bam_filtered "$bam_filtered" --class=file
    dx-jobutil-add-output bam_filtered_qc "$bam_filtered_qc" --class=file

    # TEMPORARY
    dx-jobutil-add-output bam_marked "$bam_marked" --class=file
    # TEMPORARY

    dx-jobutil-add-output prefiltered_all_reads "$prefiltered_all_reads" --class=string
    dx-jobutil-add-output prefiltered_mapped_reads "$prefiltered_mapped_reads" --class=string
    dx-jobutil-add-output filtered_mapped_reads "$filtered_mapped_reads" --class=string
    dx-jobutil-add-output metadata "{ $qc_filtered }" --class=string

    echo "* Finished."
}
