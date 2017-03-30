#!/usr/bin/env nextflow

/*
vim: syntax=groovy
-*- mode: groovy;-*-
*/

log.info "--------------------------"
log.info "TICCL Pipeline"
log.info "--------------------------"

params.virtualenv = ""
params.language = "nld"
params.extension = "folia.xml"
params.outputdir = "folia_ticcl_output"
params.inputclass = "OCR"
params.lexicon = ""
params.artifrq = 10000000
params.alphabet = ""
params.distance = 2
params.clip = 10
params.threads = 6

if (params.containsKey('help') || !params.containsKey('inputdir') || !params.containsKey('lexicon') || !params.containsKey('alphabet') || !params.containsKey('charconfus')) {
    log.info "Usage:"
    log.info "  ticcl.nf [OPTIONS]"
    log.info ""
    log.info "Mandatory parameters:"
    log.info "  --inputdir DIRECTORY     Input directory (FoLiA documents with an OCR text layer)"
    log.info "  --lexicon FILE           Path to lexicon file (*.dict)"
    log.info "  --alphabet FILE          Path to alphabet file (*.chars)"
    log.info "  --charconfus FILE        Path to character confusion list (*.confusion)"
    log.info""
    log.info "Optional parameters:"
    log.info "  --outputdir DIRECTORY    Output directory (FoLiA documents)"
    log.info "  --language LANGUAGE      Language"
    log.info "  --extension STR          Extension of FoLiA document in input directory (default: folia.xml)"
    log.info "  --inputclass CLASS       FoLiA text class to use for input, defaults to 'OCR', may be set to 'current' as well"
    log.info "  --virtualenv PATH        Path to Virtual Environment to load (usually path to LaMachine)"
    log.info "  --artifrq INT            Default value for missing frequencies in the validated lexicon (default: 10000000)"
    log.info "  --distance INT           Levenshtein/edit distance (default: 2)"
    log.info "  --clip INT               Limit the number of variants per word (default: 10)"
    log.info "  --threads INT            Number of cores to use for multi-threaded tasks (defaults to --cores)"
    exit 2
}


lexicon = Channel.fromPath(params.lexicon).ifEmpty("Lexicon file not found")
alphabet = Channel.fromPath(params.alphabet).ifEmpty("Alphabet file not found")

charconfuslist = Channel.fromPath(params.charconfus).ifEmpty("Character confusion file not found")


folia_ocr_documents = Channel.fromPath(params.inputdir+"/**." + params.extension).ifEmpty("No input documents found")
folia_ocr_documents.into { folia_ocr_documents_forcorpusfrequency; folia_ocr_documents_forfoliacorrect }

process corpusfrequency {
    //Process corpus into frequency file for TICCL
    input:
    file "doc*." + params.extension from folia_ocr_documents_forcorpusfrequency
    val virtualenv from params.virtualenv
    val inputclass from params.inputclass
    val threads from params.threads

    output:
    file "corpus.wordfreqlist.tsv" into corpusfreqlist

    script:
    """
    set +u
    if [ ! -z "${virtualenv}" ]; then
        source ${virtualenv}/bin/activate
    fi
    set -u

    FoLiA-stats --class "$inputclass" -s -t $threads -e folia.xml --lang=none --ngram 1 -o corpus .
    """
}

process ticclunk {
    //Filter a wordfrequency list

    input:
    file corpusfreqlist from corpusfreqlist //corpus frequency list in FoLiA-stats format
    file lexicon from lexicon
    val virtualenv from params.virtualenv
    val artifrq from params.artifrq

    output:
    file "${corpusfreqlist}.clean" into corpusfreqlist_clean //cleaned wordfrequency file
    file "${corpusfreqlist}.unk" into unknownfreqlist //unknown words list
    file "${corpusfreqlist}.punct" into punctuationmap //list of words mapping strings with leading/trailing punctuation to clean variants

    script:
    """
    set +u
    if [ ! -z "${virtualenv}" ]; then
        source ${virtualenv}/bin/activate
    fi
    set -u

    TICCL-unk --corpus ${lexicon} --artifrq ${artifrq} ${corpusfreqlist}
    """
}

//split channel
corpusfreqlist_clean.into { corpusfreqlist_clean_foranahash; corpusfreqlist_clean_forresolver; corpusfreqlist_clean_forindexer }

process anahash {
    /*
        Read a clean wordfrequency list , and hash all items.
    */

    input:
    file corpusfreqlist from corpusfreqlist_clean_foranahash
    file alphabet from alphabet
    val virtualenv from params.virtualenv
    val artifrq from params.artifrq

    output:
    file "${corpusfreqlist}.anahash" into anahashlist
    file "${corpusfreqlist}.corpusfoci" into corpusfocilist

    script:

	"""
    set +u
    if [ ! -z "${virtualenv}" ]; then
        source ${virtualenv}/bin/activate
    fi
    set -u

    TICCL-anahash --alph ${alphabet} --artifrq ${artifrq} ${corpusfreqlist}
    """
}


//split channels
anahashlist.into { anahashlist_forindexer; anahashlist_forresolver }
charconfuslist.into { charconfuslist_forindexer; charconfuslist_forrank }

process indexer {
    //Computes an index from anagram hashes to
    cpus params.threads

    input:
    file corpusfreqlist from corpusfreqlist_clean_forindexer //only used for naming purposes, not real input
    file anahashlist from anahashlist_forindexer
    file charconfuslist from charconfuslist_forindexer
    file corpusfocilist from corpusfocilist
    val virtualenv from params.virtualenv
    val threads from params.threads

    output:
    file "${corpusfreqlist}.indexNT" into index

    script:
    """
    set +u
    if [ ! -z "${virtualenv}" ]; then
        source ${virtualenv}/bin/activate
    fi
    set -u

    TICCL-indexerNT --hash ${anahashlist} --charconf ${charconfuslist} --foci ${corpusfocilist} -o ${corpusfreqlist} -t ${threads}
    """
    // -o option is a prefix only, extension indexNT will be appended
}

process resolver {
    //Resolves numerical confusions back to word form confusions using TICCL-LDcalc
    cpus params.threads

    input:
    file index from index
    file anahashlist from anahashlist_forresolver
    file corpusfreqlist from corpusfreqlist_clean_forresolver
    val distance from params.distance
    val artifrq from params.artifrq
    val virtualenv from params.virtualenv
    val threads from params.threads

    output:
    file "${corpusfreqlist}.ldcalc" into wordconfusionlist

    script:
    """
    set +u
    if [ ! -z "${virtualenv}" ]; then
        source ${virtualenv}/bin/activate
    fi
    set -u

	TICCL-LDcalc --index ${index} --hash ${anahashlist} --clean ${corpusfreqlist} --LD ${distance} --artifrq ${artifrq} -o ${corpusfreqlist}.ldcalc -t ${threads}
    """
}

alphabet_forrank = Channel.fromPath(params.alphabet)

process rank {
    cpus params.threads

    input:
    file wordconfusionlist from wordconfusionlist
    file alphabet from alphabet_forrank
    file charconfuslist from charconfuslist_forrank
    val distance from params.distance
    val artifrq from params.artifrq
    val clip from params.clip
    val virtualenv from params.virtualenv
    val threads from params.threads

    output:
    file "${wordconfusionlist}.ranked" into rankedlist

    script:
    """
    set +u
    if [ ! -z "${virtualenv}" ]; then
        source ${virtualenv}/bin/activate
    fi
    set -u

    TICCL-rank --alph ${alphabet} --charconf ${charconfuslist} -o ${wordconfusionlist}.ranked --debugfile ${wordconfusionlist}.debug.ranked --artifrq ${artifrq} --clip ${clip} --skipcols=10,11  -t ${threads} ${wordconfusionlist}
    """
}

process foliacorrect {
    publishDir params.outputdir, mode: 'copy', overwrite: true

    cpus params.threads

    input:
    file "doc*." + params.extension from folia_ocr_documents_forfoliacorrect
    file rankedlist from rankedlist
    file punctuationmap from punctuationmap
    file unknownfreqlist from unknownfreqlist
    val extension from params.extension
    val virtualenv from params.virtualenv
    val threads from params.threads

    output:
    file "*.folia.ticcl.xml" into folia_ticcl_documents //pending https://github.com/LanguageMachines/ticcltools/issues/3

    script:
    """
    set +u
    if [ ! -z "${virtualenv}" ]; then
        source ${virtualenv}/bin/activate
    fi
    set -u

    #some bookkeeping
    mkdir inputdir
    mv *.${extension} inputdir

    FoLiA-correct --nums 10 -e ${extension} -O . --unk ${unknownfreqlist} --punct ${punctuationmap} --rank ${rankedlist}  -t ${threads} inputdir
    """
}


folia_ticcl_documents.subscribe { println it }
