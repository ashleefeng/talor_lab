#! /usr/bin/env bash

# ./10-bed2mat.sh -i hg38.fa.fai -r hg38.fa -m ../../data/pwm/20180217_JASPAR2018_combined_matrices_31015_meme_human_537_TFs.txt -d human_pwm_ids_sorted.txt 00-test.bed 10-test


usage() {
	cat <<__EOF__
Usage: $0 [options] peaks.bed outdir

Mandatory options:
	-i REFERENCE.fa.fai  File containing the reference genome index 
	-r REFERENCE.fa      Fasta sequence of the reference genome 
	-m PWM.txt           Target motifs
	-d PWM_ids.txt       List of PWM id's

__EOF__
  exit 2
}


# from hotspot2.sh
require_exes() {
  for x in "$@"; do
    if ! which "$x" &>/dev/null; then
      echo "Could not find $x!"
      exit -1
    fi
  done
}

NUM_EXP_ARGS=10
E_WRONG_ARGS=85

if [ $# -ne $NUM_EXP_ARGS ]; then
	usage 
fi


INDEX_FILE=""
REF_FA_FILE=""
PWM_FILE=""
PWM_ID_FILE=""


while getopts 'i:r:m:d:' opt; do
	case "$opt" in
		i)
			INDEX_FILE=$OPTARG
			;;
		r)
			REF_FA_FILE=$OPTARG
			;;
		m)
			PWM_FILE=$OPTARG
			;;
		d)
			PWM_ID_FILE=$OPTARG
	esac
done

if [ "$INDEX_FILE" == "" ]; then
	echo -e "Error: Required argument -i REFERENCE.fa.fai was not provided."
	usage 
fi

if [ ! -e "$INDEX_FILE" ]; then
	echo -e "Error: REFERENCE.fa.fai file \"$INDEX_FILE\" was not found."
	usage 
fi

if [ "$REF_FA_FILE" == "" ]; then 
	echo -e "Error: Required argument -r REFERENCE.fa was not provided."
	usage 
fi

if [ ! -e "$REF_FA_FILE" ]; then
	echo -e "Error: REFERENCE.fa file \"$REF_FA_FILE\" was not found."
	usage 
fi

if [ "$PWM_FILE" == "" ]; then 
	echo -e "Error: Required argument -m PWM.txt was not provided."
	usage 
fi

if [ ! -e "$PWM_FILE" ]; then
	echo -e "Error: PWM.txt file \"$PWM_FILE\" was not found."
	usage 
fi

if [ "$PWM_ID_FILE" == "" ]; then 
	echo -e "Error: Required argument -m PWM_ids.txt was not provided."
	usage 
fi

if [ ! -e "$PWM_ID_FILE" ]; then
	echo -e "Error: PWM_ids.txt file \"$PWM_ID_FILE\" was not found."
	usage 
fi

shift $(($OPTIND - 1))

if [[ -z "$1" || -z "$2" ]]; then 
	echo -e "Error: Required argument peaks.bed or outdir was not provided."
	usage 
fi

PEAKS_FILE=$1
OUTDIR=$2

echo "Checking system for required executables..."

require_exes bedtools fimo 00-random_sampler.py 011-NNN_remover.py 012-fasta2bed.py 02-matrix_constructor.py

echo "Generating training datasets..."

if [ ! -d "$OUTDIR" ]; then
	mkdir $OUTDIR
fi

00-random_sampler.py $PEAKS_FILE $INDEX_FILE $OUTDIR

PEAKS_BASE=`basename $PEAKS_FILE .bed`
PEAKS_PREFIX="${OUTDIR}/$PEAKS_BASE"
PEAKS_SORTED_BED="${PEAKS_PREFIX}_peaks_sorted.bed"
PEAKS_SORTED_FA="${PEAKS_PREFIX}_peaks_sorted.fasta"
NONPEAKS_TEMP_BED="${PEAKS_PREFIX}_nonpeaks_temp.bed"
NONPEAKS_TEMP_FA="${PEAKS_PREFIX}_nonpeaks_temp.fasta"
NONPEAKS_BED="${PEAKS_PREFIX}_nonpeaks.bed"
NONPEAKS_FA="${PEAKS_PREFIX}_nonpeaks.fasta"

if [ ! -e "$PEAKS_SORTED_BED" ];  then 
	echo -e "Error: $PEAKS_SORTED_BED was not successfully created."
	exit -1 
fi
if [ ! -e "$NONPEAKS_TEMP_BED" ]; then 
	echo -e "Error: $NONPEAKS_TEMP_BED was not successfully created."
	exit -1
fi

bedtools getfasta -fi $REF_FA_FILE -bed $NONPEAKS_TEMP_BED -fo $NONPEAKS_TEMP_FA

if [ "$?" != "0" ]; then
	echo -e "Error when running bedtools getfasta on $NONPEAKS_TEMP_BED"
	exit -1
fi 

bedtools getfasta -fi $REF_FA_FILE -bed $PEAKS_SORTED_BED -fo $PEAKS_SORTED_FA

if [ "$?" != "0" ]; then
	echo -e "Error when running bedtools getfasta on $PEAKS_SORTED_BED"
	exit -1
fi 

011-NNN_remover.py $NONPEAKS_TEMP_FA $NONPEAKS_FA
012-fasta2bed.py $NONPEAKS_FA $NONPEAKS_BED

# fimo

PEAKS_FIMO="${PEAKS_PREFIX}_peaks_sorted_fimo.txt"
NONPEAKS_FIMO="${PEAKS_PREFIX}_nonpeaks_fimo.txt"

echo "Running liquidator on $PEAKS_SORTED_FA..."

motif_liquidator $PWM_FILE $PEAKS_SORTED_FA -o $PEAKS_FIMO

if [ "$?" != "0" ]; then
	echo -e "Error when running liquidator on $PEAKS_SORTED_FA"
	exit -1
fi 

echo "Running liquidator on $NONPEAKS_FA..."

motif_liquidator $PWM_FILE $NONPEAKS_FA -o $NONPEAKS_FIMO

if [ "$?" != "0" ]; then
	echo -e "Error when running liquidator on $NONPEAKS_FA"
	exit -1
fi

# Construct training matrices

PEAKS_MAT="${PEAKS_PREFIX}_peaks_matrix.tsv"
NONPEAKS_MAT="${PEAKS_PREFIX}_nonpeaks_matrix.tsv"
ALL_MAT="${PEAKS_PREFIX}_all_matrix.tsv"

echo "Constructing matrix for peaks..."

02-matrix_constructor_liq.py $PEAKS_SORTED_BED $PEAKS_FIMO $PWM_ID_FILE $PEAKS_MAT

if [ "$?" != "0" ];  then 
	echo -e "Error when running constructing matrix for peaks."
	exit -1 
fi

echo "Constructing matrix for nonpeaks..."

02-matrix_constructor_liq.py $NONPEAKS_BED $NONPEAKS_FIMO $PWM_ID_FILE $NONPEAKS_MAT

if [ "$?" != "0" ];  then 
	echo -e "Error when running constructing matrix for nonpeaks."
	exit -1 
fi

echo "Contatenating two matrices..."

cp $PEAKS_MAT $ALL_MAT
cat $NONPEAKS_MAT >> $ALL_MAT

echo
echo "Results:"
echo "   $PEAKS_MAT"
echo "   $NONPEAKS_MAT"
echo "   $ALL_MAT"

exit $?

			
