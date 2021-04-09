#include "Film.h"

#include <iostream>
#include "../Utils/GpuCommons.h"



Film::Film():samplesSum(0,true),samplesCount(0,true){}

Film::Film(int width_, int height_,bool isCopyForKernel_):
samplesSum(width_*height_, isCopyForKernel_),
samplesCount(width_*height_, isCopyForKernel_)
{
	width = width_;
    height = height_;
}


__global__
void apply(int pixelsCount, Spectrum* samplesSum, int* samplesCount, unsigned char* data){
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= pixelsCount) {
        return;
    }
    Spectrum spectrum = samplesSum[index] / (float)samplesCount[index];
    writeColorAt(clampBetween0And1(spectrum),&(data[index*3]));
}


RenderResult Film::readCurrentResult(){

    int pixelsCount = width*height;

    GpuArray<unsigned char> data(pixelsCount*3,false);

    int numThreads = min(pixelsCount,MAX_THREADS_PER_BLOCK);
    int numBlocks = divUp(pixelsCount,numThreads);

    apply<<<numBlocks,numThreads>>> (pixelsCount,samplesSum.data,samplesCount.data,data.data);
    CHECK_CUDA_ERROR("apply box filter");

    RenderResult result(width,height);
    HANDLE_ERROR(cudaMemcpy(result.data.data(),data.data,3*width*height*sizeof(unsigned char),cudaMemcpyDeviceToHost));
    return result;
}


Film Film::getCopyForKernel() {
    Film copy(width,height,true);
    copy.samplesSum = samplesSum.getCopyForKernel();
    copy.samplesCount = samplesCount.getCopyForKernel();
    return copy;
}

Film Film::createFromParams(const Parameters& params){
	int width = params.getNum("xresolution");
	int height = params.getNum("yresolution");
	return Film(width,height,false);
}