#include "ReinforcementLearningPathTracing.h"
#include "../Samplers/SimpleSampler.h"
#include "../Utils/TaskQueue.h"
#include "../Core/Impl.h"
#include "../Utils/Timer.h"
#include "../Utils/Utils.h"

namespace ReinforcementLearningPathTracing {

#define Q_TABLE_SIZE 64

    using QDistribution = FixedSizeDistribution1D<QEntry::NUM_XY>;

    RLPTIntegrator::RLPTIntegrator(int maxDepth_):maxDepth(maxDepth_),QTable(Q_TABLE_SIZE*Q_TABLE_SIZE*Q_TABLE_SIZE,false) {

    }

    struct QEntryInfo {
        int entryIndex = -1;
        int cellIndex = -1;
    };

    __device__
    int findQEntry(const AABB& sceneBounds, float3 position){
        float3 sceneSize = sceneBounds.maximum-sceneBounds.minimum;
        float3 entrySize = sceneSize / make_float3(Q_TABLE_SIZE,Q_TABLE_SIZE,Q_TABLE_SIZE);
        int3 entryIndex;
        position -= sceneBounds.minimum;
        entryIndex.x = clampF((int)(position.x / entrySize.x),0,Q_TABLE_SIZE-1);
        entryIndex.y = clampF((int)(position.y / entrySize.y),0,Q_TABLE_SIZE-1);
        entryIndex.z = clampF((int)(position.z / entrySize.z),0,Q_TABLE_SIZE-1);
        return entryIndex.x * Q_TABLE_SIZE * Q_TABLE_SIZE + entryIndex.y * Q_TABLE_SIZE + entryIndex.z;
    }

    struct RayTask {
        SamplingState samplingState;
        Ray ray;
        Spectrum multiplier;
        Spectrum* result;
        float surfacePDF; // if the ray is generated by sampling a BSDF, this is the PDF of that sample. This is needed for MIS
        bool sampledFromDeltaBSDF;
        QEntryInfo previousQEntry;
    };

    struct LightingTask {
        SamplingState samplingState;
        IntersectionResult intersection;
        Ray thisRay;
        Spectrum multiplier;
        Spectrum* result;
        float surfacePDF;
        bool sampledFromDeltaBSDF;
        QEntryInfo previousQEntry;
    };

    struct LightingResult {
        Spectrum lightingContrib;
        float3 rayToLightDirection;
        float lightPDF;
    };

    struct NextRayInfo {
        float3 dir;
        float surfacePDF;
        int cellIndex;
    };

    __device__
    inline float misPowerHeuristic(float pdfA, float pdfB) {
        pdfA *= pdfA;
        pdfB *= pdfB;
        return pdfA / (pdfA + pdfB);
    }

    
    // use q entry index as part of the key for sorting. this improves locality.
    __global__
    void writeIndicesAndKeys(int N, LightingTask* tasks, int* indices, int* keys,AABB sceneBounds) {
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= N) {
            return;
        }
        
        indices[index] = index;
        int materialID = static_cast<int>(tasks[index].intersection.primitive->material.getType());
        int entryIndex = findQEntry(sceneBounds, tasks[index].intersection.position);

        int key = Q_TABLE_SIZE * Q_TABLE_SIZE * Q_TABLE_SIZE * materialID + entryIndex;
        keys[index] = key;
    }

    __global__
    void applySortedIndices(int N,int* sortedIndices, LightingTask* lightTasks, LightingTask* lightTasksCopy) {
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= N) {
            return;
        }
        lightTasksCopy[index] = lightTasks[sortedIndices[index]];        
    }

    // sort the lighting queue using material and q entry id as key.
    void sortLightingQueue(TaskQueue<LightingTask>& lightQueue, TaskQueue<LightingTask>& lightQueueCopy, AABB sceneBounds) {
        int N = lightQueue.count();
        if (N == 0) return;

        lightQueueCopy.setCount(N);

        GpuArray<int> indices(N);
        GpuArray<int> keys(N);

        int numBlocks, numThreads;
        setNumBlocksThreads(N, numBlocks, numThreads);

        writeIndicesAndKeys << <numBlocks, numThreads >> > (N, lightQueue.tasks.data, indices.data, keys.data,sceneBounds);
        CHECK_CUDA_ERROR("write indices and keys");

        thrust::stable_sort_by_key(thrust::device, keys.data, keys.data+N, indices.data);

        applySortedIndices << <numBlocks, numThreads >> > (N,indices.data, lightQueue.tasks.data, lightQueueCopy.tasks.data);
        CHECK_CUDA_ERROR("apply sort");
        std::swap(lightQueue.tasks.data, lightQueueCopy.tasks.data);

    }


    __global__
    void intersectScene( SceneHandle scene, SamplerObject sampler, TaskQueue<LightingTask> lightingQueue,TaskQueue<RayTask> thisRoundRayQueue, TaskQueue<RayTask> nextRoundRayQueue,int depth) {
        int raysCount = thisRoundRayQueue.count();
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= raysCount) {
            return;
        }

        RayTask& myTask = thisRoundRayQueue.tasks.data[index];
        Spectrum* result = myTask.result;
        Spectrum multiplier = myTask.multiplier;
        Ray thisRay = myTask.ray;
        

        IntersectionResult intersection;
        scene.intersect(intersection, thisRay);

        if (!intersection.intersected) {
            if (scene.hasEnvironmentMap()) {
                *result += scene.getEnvironmentMap()->EnvironmentMap::evaluateRay(thisRay) * multiplier;
            }
            return;
        }
        
        LightingTask lightingTask = { myTask.samplingState, intersection,thisRay,multiplier,result,myTask.surfacePDF,myTask.sampledFromDeltaBSDF,myTask.previousQEntry };
        lightingQueue.push(lightingTask);
        
    }

    __global__
    void genNextRay(SceneHandle scene, SamplerObject sampler, TaskQueue<LightingTask> tasks, TaskQueue<RayTask> nextRoundRayQueue, int depth, AABB sceneBounds, GpuArray<QEntry> QTable,GpuArray<NextRayInfo> nextRayInfos) {
        int tasksCount = tasks.count();
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= tasksCount) {
            return;
        }

        LightingTask& myTask = tasks.tasks.data[index];
        IntersectionResult intersection = myTask.intersection;
        Spectrum* result = myTask.result;
        Ray thisRay = myTask.thisRay;
        Spectrum multiplier = myTask.multiplier;

        //russian roulette
        if (depth > 3) {
            float terminationProbability = 1;
            terminationProbability = min(terminationProbability, 1 - multiplier.x);
            terminationProbability = min(terminationProbability, 1 - multiplier.y);
            terminationProbability = min(terminationProbability, 1 - multiplier.z);

            terminationProbability = max(terminationProbability, 0.05f);

            if (sampler.rand1(myTask.samplingState) < terminationProbability) {
                return;
            }
            multiplier = multiplier / (1.f - terminationProbability);
        }

        const Primitive* prim = intersection.primitive;         

        Ray nextRay;
        float nextRayProbability;

        float3 tangent0, tangent1;
        intersection.findTangents(tangent0, tangent1);

        float3 exitantDir = thisRay.direction * -1.f;

        QEntryInfo entryInfo;
        entryInfo.entryIndex = findQEntry(sceneBounds, intersection.position);

        Spectrum nextMultiplier;

        if (intersection.bsdf.isDelta()) {
            float3 nextDirectionLocal;
            nextMultiplier = intersection.bsdf.sample(sampler.rand2(myTask.samplingState), nextDirectionLocal, intersection.worldToLocal(exitantDir,tangent0,tangent1), &nextRayProbability);
            nextRay.direction = intersection.localToWorld(nextDirectionLocal);
            nextRay.origin = intersection.position + nextRay.direction * 0.0001f;
            entryInfo.cellIndex = QEntry::dirToCellIndex(nextRay.direction);
        }
        else {
            NextRayInfo& info = nextRayInfos.data[index];

            entryInfo.cellIndex = info.cellIndex;
            nextRayProbability = info.surfacePDF;
            nextRay.direction = info.dir;
            nextRay.origin = intersection.position + nextRay.direction * 0.0001f;

            nextMultiplier = intersection.bsdf.eval(intersection.worldToLocal(nextRay.direction, tangent0, tangent1), intersection.worldToLocal(exitantDir, tangent0, tangent1));
        }

        if (isAllZero(nextMultiplier)) {
            multiplier = make_float3(0, 0, 0);
        }
        else {
            multiplier = multiplier * nextMultiplier * abs(dot(nextRay.direction, intersection.normal)) / nextRayProbability;
        }

        RayTask nextTask = { myTask.samplingState, nextRay,multiplier,result,nextRayProbability, intersection.bsdf.isDelta(),entryInfo };
        nextRoundRayQueue.push(nextTask);
    }


    __global__
    void computeLighting(SceneHandle scene, SamplerObject sampler, TaskQueue<LightingTask> tasks, int depth,AABB sceneBounds,GpuArray<QEntry> QTable,GpuArray<LightingResult> results) {
        int tasksCount = tasks.count();
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= tasksCount) {
            return;
        }

        LightingTask& myTask = tasks.tasks.data[index];
        IntersectionResult intersection = myTask.intersection;
        Spectrum* result = myTask.result;
        Ray thisRay = myTask.thisRay;
        Spectrum multiplier = myTask.multiplier;
        QEntryInfo& previousQEntry = myTask.previousQEntry;

        const Primitive* prim = intersection.primitive;

        if (prim->areaLight) {
            if (myTask.sampledFromDeltaBSDF) {
                // then don't apply MIS, because the sampleRayToPoint call had a 0 probability of finding any radiance;
                *result += prim->areaLight->get<DiffuseAreaLight>()->DiffuseAreaLight::evaluateRay(thisRay,intersection) * multiplier;
            }
            else {
                if (depth > 0 && false) {
                    float surfacePDF = myTask.surfacePDF;
                    float lightPDF = prim->areaLight->get<DiffuseAreaLight>()->DiffuseAreaLight::sampleRayToPointPdf(thisRay, intersection);
                    float misWeight = misPowerHeuristic(surfacePDF, lightPDF);
                    if (isfinite(misWeight)) {
                        *result += prim->areaLight->get<DiffuseAreaLight>()->DiffuseAreaLight::evaluateRay(thisRay, intersection) * multiplier * misWeight;
                    }
                }
            }
        }

        Ray exitantRay = { intersection.position,thisRay.direction * -1 };

        int lightIndex = sampler.randInt(scene.lightsCount,myTask.samplingState);

        const LightObject& light = scene.lights[lightIndex];
        Ray rayToLight;
        float probability;
        float4 randomSource = sampler.rand4(myTask.samplingState);

        VisibilityTest visibilityTest;
        visibilityTest.sourceMeshIndex = intersection.primitive->shape.meshIndex;

        Spectrum incident = light.sampleRayToPoint(intersection.position, sampler,myTask.samplingState, probability, rayToLight, visibilityTest, nullptr);

        if (!(scene.testVisibility(visibilityTest) && isfinite(probability))) {
            // then light is occluded. But still call materialEval in order to update Q.
            incident = make_float3(0, 0, 0); 
            probability = 1;
        }
        Spectrum lightingContrib = intersection.primitive->material.eval(rayToLight, incident, exitantRay, intersection);
        lightingContrib *= scene.lightsCount / probability;

        results.data[index].lightingContrib = lightingContrib;
        results.data[index].lightPDF = probability;
        results.data[index].rayToLightDirection = rayToLight.direction;

    }

    __global__
    void computeQDistributions(SceneHandle scene,TaskQueue<LightingTask> lightingTasks, GpuArray<LightingResult> lightingResults, AABB sceneBounds,GpuArray<QEntry> QTable,SamplerObject sampler,GpuArray<NextRayInfo> nextRayInfos) {
        int tasksCount = lightingTasks.count();
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= tasksCount) {
            return;
        }

        LightingTask& myTask = lightingTasks.tasks.data[index];
        IntersectionResult& intersection = myTask.intersection;
        Spectrum* result = myTask.result;
        Spectrum& multiplier = myTask.multiplier;
        QEntryInfo previousQEntry = myTask.previousQEntry;

        float3 incidentDir = lightingResults.data[index].rayToLightDirection;
        float3 exitantDir = myTask.thisRay.direction * -1.f;

        

        float sumWeightedQ = 0.f; // This will be used for two different things: updating Q table, and computing surfacePDF (for MIS);

        int thisQEntryIndex = findQEntry(sceneBounds, intersection.position);
        QEntry& thisEntry = QTable.data[thisQEntryIndex];

        float3 tangent0, tangent1;
        intersection.findTangents(tangent0, tangent1);
        float3 exitantLocal = intersection.worldToLocal(exitantDir, tangent0, tangent1);

        QDistribution dist;

        for (int cellIndex = 0; cellIndex < QEntry::NUM_XY; ++cellIndex) {
            int thetaIdx = cellIndex / QEntry::NUM_X;
            int phiIdx = cellIndex % QEntry::NUM_X;
            float u = ((float)thetaIdx + 0.5f) * QEntry::INV_NUM_Y();
            u = u * 2 - 1.f;
            float v = ((float)phiIdx + 0.5f) * QEntry::INV_NUM_X();

            float xyScale = sqrt(1.0f - u * u);
            float phi = 2 * M_PI * v;
            float3 dir = make_float3(
                xyScale * cos(phi),
                xyScale * sin(phi),
                u);
            float3 incidentLocal = intersection.worldToLocal(dir, tangent0, tangent1);

            float scattering = luminance(intersection.bsdf.eval(incidentLocal, exitantLocal));
            float thisDirQ = abs(dot(dir, intersection.normal)) * scattering * thisEntry.Q[cellIndex];
            sumWeightedQ += thisDirQ;
            dist.cdf[cellIndex] = thisDirQ;
        }
        float accumulatedDensity = 0;
        for (int cellIndex = 0; cellIndex < QEntry::NUM_XY; ++cellIndex) {
            float density = dist.cdf[cellIndex] / sumWeightedQ;
            accumulatedDensity += density;
            dist.cdf[cellIndex] = accumulatedDensity;
        }

        sumWeightedQ *= (4.f * M_PI / (float)QEntry::NUM_XY);

        // updated Q
        if (previousQEntry.entryIndex != -1) {
            // update q table
            float proposal = sumWeightedQ + luminance(lightingResults.data[index].lightingContrib);
            QTable.data[previousQEntry.entryIndex].proposeNextQ(proposal, previousQEntry.cellIndex);
        }

        // compute MIS
        int rayToLightCellIndex = QEntry::dirToCellIndex(exitantDir);
        float surfacePDF = dist.cdf[rayToLightCellIndex];
        if (rayToLightCellIndex > 0) {
            surfacePDF -= dist.cdf[rayToLightCellIndex-1];
        }
        if (sumWeightedQ == 0) {
            surfacePDF = 0;
        }
        float lightPDF = lightingResults.data[index].lightPDF;
        float misWeight = misPowerHeuristic(lightPDF, surfacePDF);

        *result += lightingResults.data[index].lightingContrib * multiplier * misWeight;

        // sample next ray Dir
        float& nextRayProbability = nextRayInfos.data[index].surfacePDF;
        nextRayInfos.data[index].cellIndex = dist.sample(sampler.rand1(myTask.samplingState), nextRayProbability);
        nextRayProbability = (QEntry::NUM_XY * nextRayProbability / (4 * M_PI)); // Solid angle probability

        nextRayInfos.data[index].dir = thisEntry.sampleDirectionInCell(sampler.rand2(myTask.samplingState), nextRayInfos.data[index].cellIndex, intersection.normal, exitantDir);

    }


    __global__
    void genInitialRays(CameraSample* samples, int samplesCount, CameraObject camera, Spectrum* results, TaskQueue<RayTask> rayQueue,SamplerObject sampler,unsigned long long lastSampleIndex) {
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= samplesCount) {
            return;
        }

        Ray ray = camera.genRay(samples[index]);
        Spectrum* result = &results[index];
        *result = make_float3(0, 0, 0);
        Spectrum multiplier = make_float3(1, 1, 1);
        QEntryInfo nullEntry = { -1,-1};

        SamplingState samplingState;
        sampler.startPixel(samplingState, lastSampleIndex);

        RayTask task = {samplingState,ray,multiplier,result,1,true,nullEntry };
        rayQueue.push(task);
    }

     


    __global__
    void addSamplesToFilm(FilmObject film, Spectrum* result, CameraSample* samples, int count) {
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= count) {
            return;
        }
        film.addSample(samples[index], result[index]);
    }

    template<typename TaskType>
    __global__
    void findMaxDimension(TaskType* tasks, int N, int* maxDimension) {
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= N) {
            return;
        }
        int dim = tasks[index].samplingState.dimension;
        atomicMax(maxDimension, dim);
    }

    template<typename TaskType>
    __global__
    void setMaxDimension(TaskType* tasks, int N, int* maxDimension) {
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= N) {
            return;
        }
        tasks[index].samplingState.dimension = *maxDimension;
    }

    template<typename TaskType>
    void syncDimension(TaskType* tasks, int N, GpuArray<int>& maxDimension) {
        int numBlocks, numThreads;
        setNumBlocksThreads(N, numBlocks, numThreads);

        maxDimension.set(0, 0);

        findMaxDimension << <numBlocks, numThreads >> > (tasks, N, maxDimension.data);
        CHECK_CUDA_ERROR("write max halton dimension");
        std::cout << "maxDimension: " << maxDimension.get(0) << std::endl;

        setMaxDimension << <numBlocks, numThreads >> > (tasks, N, maxDimension.data);
        CHECK_CUDA_ERROR("sync halton dimension");
    }

    __global__
    void initialiseQTable(GpuArray<QEntry> QTable){
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= QTable.N) {
            return;
        }
        QTable.data[index] = QEntry();
    }

    __global__
    void prepareForUpdateQ(GpuArray<QEntry> QTable){
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= QTable.N*QEntry::NUM_XY) {
            return;
        }
        int entryIndex = index / QEntry::NUM_XY;
        int cellIndex = index % QEntry::NUM_XY;
        QTable.data[entryIndex].prepareForUpdateQ(cellIndex);
    }

    __global__
    void finishUpdateQ(GpuArray<QEntry> QTable){
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        if (index >= QTable.N*QEntry::NUM_XY) {
            return;
        }
        int entryIndex = index / QEntry::NUM_XY;
        int cellIndex = index % QEntry::NUM_XY;
        QTable.data[entryIndex].finishUpdateQ(cellIndex);
    }


    void debugPrintQTable(const GpuArray<QEntry>& QTable) {
        int size = Q_TABLE_SIZE * Q_TABLE_SIZE * Q_TABLE_SIZE;
        std::vector<QEntry> table = QTable.toVector();
        for (int i = 0; i <size; ++i) {
            QEntry entry = QTable.get(i);
            std::cout << "Entry: " << i << std::endl;
            for (int y = 0; y < QEntry::NUM_Y; y++){
                std::cout << "y=" << y << "   ";
                for (int x = 0; x < QEntry::NUM_X; x++){
                    std::cout << entry.Q[x + y * QEntry::NUM_X] << "  ";
                }
                std::cout << std::endl;
            }
            std::cout << std::endl << std::endl;
        }
    }



    void RLPTIntegrator::render(const Scene& scene, const CameraObject& camera, FilmObject& film) {

        int bytesNeededPerThread = sizeof(CameraSample) + sampler->bytesNeededPerThread() + sizeof(Spectrum) + sizeof(RayTask)*2 + sizeof(LightingTask)*2 + sizeof(LightingResult)+sizeof(NextRayInfo)+4*sizeof(int) ;
        std::cout<<"Running RL Path Tracing Integrator. Bytes needed per thread: "<<bytesNeededPerThread<<std::endl;

        int numBlocks, numThreads;
        setNumBlocksThreads(QTable.N, numBlocks, numThreads);
        initialiseQTable<<<numBlocks,numThreads>>>(QTable.getCopyForKernel());

        int round = 0;

        unsigned long long lastSampleIndex = -1;
        GpuArray<int> maxDimension(1);

        while(!isFinished( scene, camera,  film)){
            GpuArray<CameraSample> allSamples = sampler->genAllCameraSamples(camera, film, bytesNeededPerThread);

            SceneHandle sceneHandle = scene.getDeviceHandle();
    
            SamplerObject& samplerObject = *sampler;
    
    
            int samplesCount = (int)allSamples.N;
            setNumBlocksThreads(samplesCount, numBlocks, numThreads);

            sampler->prepare(samplesCount);

            //debugTestEntrySampling << <1, 1 >> > (samplerObject);
            //SIGNAL_ERROR("done testing\n");
    
            GpuArray<Spectrum> result(samplesCount);

            TaskQueue<RayTask> rayQueue0(samplesCount);
            TaskQueue<RayTask> rayQueue1(samplesCount);
    
            TaskQueue<RayTask>* thisRoundRayQueue = &rayQueue0;
            TaskQueue<RayTask>* nextRoundRayQueue = &rayQueue1;

            TaskQueue<LightingTask> lightingQueue(samplesCount);
            TaskQueue<LightingTask> lightingQueueCopy(samplesCount);

            GpuArray<LightingResult> lightingResults(samplesCount);
            GpuArray<NextRayInfo> nextRayInfos(samplesCount);

            int QCellsCount = QTable.N * QEntry::NUM_XY;

            std::cout << numBlocks << "   " << numThreads << std::endl;
            genInitialRays << <numBlocks, numThreads >> > (allSamples.data,samplesCount,camera,result.data,thisRoundRayQueue->getCopyForKernel(), samplerObject.getCopyForKernel(),lastSampleIndex);
            CHECK_CUDA_ERROR("gen initial rays");

            int depth = 0;

            lastSampleIndex += samplesCount;

            while (thisRoundRayQueue->count() > 0 && depth <= maxDepth) {
                std::cout << "\ndoing depth " << depth << std::endl;

                //if(depth>=2)  debugPrintQTable(QTable);

                thisRoundRayQueue->setNumBlocksThreads(numBlocks, numThreads);
                std::string intersectSceneEvent = std::string("intersectScene ") + std::to_string(round)+" " + std::to_string(depth);
                Timer::getInstance().timedRun(intersectSceneEvent, [&](){
                    intersectScene << <numBlocks, numThreads >> >
                        (sceneHandle, samplerObject.getCopyForKernel(), lightingQueue.getCopyForKernel(), thisRoundRayQueue->getCopyForKernel(), nextRoundRayQueue->getCopyForKernel(), depth);
                });
                

                thisRoundRayQueue->clear();


                std::string sortEvent = std::string("sort queue ") + std::to_string(round) + " " + std::to_string(depth);
                Timer::getInstance().timedRun(sortEvent, [&](){
                    sortLightingQueue(lightingQueue, lightingQueueCopy, scene.sceneBounds);
                });

                if (lightingQueue.count() > 0) {
                    setNumBlocksThreads(QCellsCount, numBlocks, numThreads);
                    prepareForUpdateQ << <numBlocks, numThreads >> > (QTable.getCopyForKernel());
                    CHECK_CUDA_ERROR("prepare update q");

                    syncDimension(lightingQueue.tasks.data, lightingQueue.count(), maxDimension);

                    lightingQueue.setNumBlocksThreads(numBlocks, numThreads);
                    std::string lightingEvent = std::string("lighting ") + std::to_string(round) + " " + std::to_string(depth);
                    Timer::getInstance().timedRun(lightingEvent, [&]() {
                        computeLighting << <numBlocks, numThreads >> > (sceneHandle, samplerObject.getCopyForKernel(), lightingQueue.getCopyForKernel(), depth,scene.sceneBounds,QTable.getCopyForKernel(), lightingResults.getCopyForKernel());
                    });


                    std::string materialEvent = std::string("compute Q ") + std::to_string(round) + " " + std::to_string(depth);
                    Timer::getInstance().timedRun(materialEvent, [&]() {
                        computeQDistributions << <numBlocks, numThreads >> > (sceneHandle, lightingQueue.getCopyForKernel(), lightingResults.getCopyForKernel(), scene.sceneBounds, QTable.getCopyForKernel(), samplerObject.getCopyForKernel(), nextRayInfos.getCopyForKernel());
                    });


                    setNumBlocksThreads(QCellsCount,numBlocks,numThreads);
                    finishUpdateQ<<<numBlocks,numThreads>>>(QTable.getCopyForKernel());
                    CHECK_CUDA_ERROR("finish update q");

                    syncDimension(lightingQueue.tasks.data, lightingQueue.count(), maxDimension);

                    lightingQueue.setNumBlocksThreads(numBlocks, numThreads);
                    std::string genNextRayEvent = std::string("genNext ") + std::to_string(round) + " " + std::to_string(depth);
                    Timer::getInstance().timedRun(genNextRayEvent, [&]() {
                        genNextRay << <numBlocks, numThreads >> > (sceneHandle, samplerObject.getCopyForKernel(), lightingQueue.getCopyForKernel(), nextRoundRayQueue->getCopyForKernel(), depth,scene.sceneBounds,QTable.getCopyForKernel(), nextRayInfos.getCopyForKernel());
                    });
                }

                lightingQueue.clear();

                ++depth;
                std::swap(thisRoundRayQueue, nextRoundRayQueue);

            }

            setNumBlocksThreads(samplesCount, numBlocks, numThreads);

            addSamplesToFilm << <numBlocks, numThreads >> > (film.getCopyForKernel(), result.data, allSamples.data, samplesCount);
            CHECK_CUDA_ERROR("add sample to film");

            ++round;


        }
        //debugPrintQTable(QTable);

    }

}
