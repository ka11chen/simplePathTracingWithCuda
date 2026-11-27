#!/bin/bash

if [[ -z "${CC:-}" ]]; then
    if command -v clang >/dev/null 2>&1; then
        CC="clang"
    else
        CC="gcc"
    fi
fi
NVCC="${NVCC:-nvcc}"
CUDA_ARCH="${CUDA_ARCH:-sm_90}"
GPU_DOUBLE="${GPU_DOUBLE:-0}"

# SDL is optional: without it only the headless --bench mode is available
if command -v sdl2-config >/dev/null 2>&1; then
    sdlCflags=$(sdl2-config --cflags)
    sdlLibs=$(sdl2-config --libs)
    sdlDefine=""
else
    sdlCflags=""
    sdlLibs=""
    sdlDefine="-DNO_SDL"
fi
buildPath="build"
binaryPath="bin"
sourcePath="src"

if [[ ! (-d $binaryPath) ]]; then
    mkdir $binaryPath
fi

if [[ ! (-d $buildPath) ]]; then
    mkdir $buildPath
fi

if [[ ! (-d $sourcePath) ]]; then
    echo "Where is your source?"
    exit 1
fi

if [[ $# != 1 ]]; then
    echo "Usage: ./makeMakefile.sh <main file>"
    exit 1
fi

optimizationFlags="-O2 -pthread -g -DDOUBLE_AS_REAL -Wall $sdlDefine"
cudaFlags="-O3 -std=c++17 -arch=$CUDA_ARCH -DDOUBLE_AS_REAL"
if [[ "$GPU_DOUBLE" == "1" ]]; then
    cudaFlags="$cudaFlags -DGPU_DOUBLE"
fi

nvccLinkFlags=""
for flag in $sdlLibs; do
    if [[ $flag == -Wl,* ]]; then
        nvccLinkFlags+="-Xlinker ${flag#-Wl,} "
    elif [[ $flag == -pthread ]]; then
        nvccLinkFlags+="-Xcompiler -pthread "
    else
        nvccLinkFlags+="$flag "
    fi
done

echo "all: $binaryPath/pathTracing"

mainDependency="$binaryPath/pathTracing: "

for file in $sourcePath/*.c $1; do
    filename=$(basename $file)
    if [[ $filename == mainOnServer.c ]]; then
        continue
    fi

    xfpref=${filename%%.*}
    mainDependency+="$buildPath/$xfpref.o "

    if [[ $filename == pathTracing.c ]]; then
        echo "$buildPath/$($CC $sdlCflags $sdlDefine -MM $file)"
        echo -e "\t$CC -o \$@ -c \$< $sdlCflags $optimizationFlags"
        echo
    else
        echo "$buildPath/$($CC -MM $file)"
        echo -e "\t$CC -o \$@ -c \$< $optimizationFlags"
        echo
    fi
done

for file in $sourcePath/*.cu; do
    [[ -e $file ]] || continue
    filename=$(basename $file)
    xfpref=${filename%%.*}
    mainDependency+="$buildPath/$xfpref.o "

    if command -v "$NVCC" >/dev/null 2>&1; then
        echo "$buildPath/$($NVCC $cudaFlags -MM $file)"
    else
        echo "$buildPath/$xfpref.o: $file $sourcePath/*.h $sourcePath/*.cuh"
    fi
    echo -e "\t$NVCC -o \$@ -c \$< $cudaFlags"
    echo
done

echo $mainDependency
echo -e "\t$NVCC \$^ -o \$@ $nvccLinkFlags -lm -lpthread"
echo
echo ".PHONY: clean"
echo "clean: "
echo -e "\t- rm $binaryPath/*"
echo -e "\t- rm $buildPath/*.o"
