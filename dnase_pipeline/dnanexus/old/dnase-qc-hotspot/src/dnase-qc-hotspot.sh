#!/bin/bash
# dnase-qc-hotspot.sh - Calls hotspots on a sample for qc for the ENCODE DNase-seq pipeline.

main() {
    echo "* Installing hotspot and dependencies (gsl)..." 2>&1 | tee -a install.log
    exe_dir="`pwd`"
    set -x
    wget ftp://ftp.gnu.org/gnu/gsl/gsl-latest.tar.gz -O gsl.tgz >> install.log 2>&1
    mkdir gsl
    tar -xzf gsl.tgz -C gsl --strip-components=1
    cd gsl
    ./configure >> install.log 2>&1
    make > install.log 2>&1
    sudo make install >> install.log 2>&1
    gsl-config --libs > install.log 2>&1
    export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH}
    cd ..
    wget https://github.com/rthurman/hotspot/archive/v4.1.0.tar.gz -O hotspot.tgz >> install.log 2>&1
    mkdir hotspot
    tar -xzf hotspot.tgz -C hotspot --strip-components=1
    cd hotspot/hotspot-distr/hotspot-deploy
    make >> install.log 2>&1
    # Can either put bin in path or copy contents of bin to /usr/bin
    export PATH=${exe_dir}/hotspot/hotspot-distr/hotspot-deploy/bin:${PATH}
    cd ../../../
    set +x; 
    # additional executables in resources/usr/bin
    
    # If available, will print tool versions to stderr and json string to stdout
    versions=''
    if [ -f /usr/bin/tool_versions.py ]; then 
        versions=`tool_versions.py --dxjson dnanexus-executable.json`
    fi

    echo "* Value of bam_to_sample: '$bam_to_sample'"
    echo "* Value of chrom_sizes: '$chrom_sizes'"
    echo "* Value of read_length: '$read_length'"
    echo "* Value of genome: '$genome'"

    echo "* Download files..."
    bam_root=`dx describe "$bam_to_sample" --name`
    bam_root=${bam_root%.bam}
    dx download "$bam_to_sample" -o ${bam_root}.bam
    
    sample_size="5000000"
    echo "* bam file: '${bam_root}.bam' will be sampled to ${5000000} reads."

    dx download "$chrom_sizes" -o chrom.sizes

    # check read_length
    if [ -f /usr/bin/parse_property.py ]; then 
        read_len=`parse_property.py -f "$bam_to_sample" -p "read_length" --quiet`
        if [ "$read_len" != "" ] && [ "$read_length" -ne "$read_len" ]; then
            if [ "$read_len" == "32" ] || [ "$read_len" == "36" ] || [ "$read_len" == "40" ] || [ "$read_len" == "50" ] \
            || [ "$read_len" == "58" ] || [ "$read_len" == "72" ] || [ "$read_len" == "76" ] || [ "$read_len" == "100" ]; then
                echo "* NOTE: Read length ($read_length) does not match discovered read size ($read_len). Using $read_len."
                read_length=$read_len
            else
                echo "* WARNING: Read length ($read_length) does not match discovered read size ($read_len)."
            fi
        fi
    fi

    echo "* ===== Calling DNAnexus and ENCODE independent script... ====="
    set -x
    dnase_qc_hotspot.sh ${bam_root}.bam chrom.sizes $genome $sample_size $read_length hotspot/
    set +x
    echo "* ===== Returned from dnanexus and encodeD independent script ====="
    scripted_root="${bam_root}_sample_${sample_size}"
    sample_root="${bam_root}_sample_5M"
    # Add DX/encodeD specific _5M qualifier
    set -x
    mv ${scripted_root}.bam ${sample_root}.bam 
    mv ${scripted_root}_edwBamStats.txt ${sample_root}_edwBamStats.txt 
    mv ${scripted_root}_hotspot_qc.txt ${sample_root}_hotspot_qc.txt 
    set +x
    echo "-- The named results..."
    ls -l ${sample_root}*

    echo "* Prepare metadata..."
    qc_sampled=''
    reads_sample=5000000
    if [ -f /usr/bin/qc_metrics.py ]; then
        qc_sampled=`qc_metrics.py -n edwBamStats -f ${sample_root}_edwBamStats.txt`
        reads_sample=`qc_metrics.py -n edwBamStats -f ${sample_root}_edwBamStats.txt -k u4mReadCount`
        meta=`qc_metrics.py -n hotspot -f ${sample_root}_hotspot_qc.txt`
        qc_sampled=`echo $qc_sampled, $meta`
    fi
    # All qc to one file per target file:
    echo "===== edwBamStats ====="      > ${sample_root}_qc.txt
    cat ${sample_root}_edwBamStats.txt >> ${sample_root}_qc.txt
    echo " "                           >> ${sample_root}_qc.txt
    echo "===== hotspot out ====="     >> ${sample_root}_qc.txt
    cat ${sample_root}_hotspot_qc.txt  >> ${sample_root}_qc.txt

    echo "* Upload results..."
    bam_sample_5M=$(dx upload ${sample_root}.bam --details "{ $qc_sampled }" --property SW="$versions" \
                                                 --property reads="$reads_sample" --property read_length="$read_len" --brief)
    bam_sample_5M_qc=$(dx upload ${sample_root}_qc.txt --details "{ $qc_sampled }" --property SW="$versions" --brief)

    dx-jobutil-add-output bam_sample_5M "$bam_sample_5M" --class=file
    dx-jobutil-add-output bam_sample_5M_qc "$bam_sample_5M_qc" --class=file

    dx-jobutil-add-output reads "$reads_sample" --class=string
    dx-jobutil-add-output metadata "$versions" --class=string

    echo "* Finished."
}
