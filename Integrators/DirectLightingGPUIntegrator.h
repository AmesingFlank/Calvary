#pragma once

#include "../Core/Integrator.h"
#include "../Core/Sampler.h"
#include <memory>

class DirectLightingGPUIntegrator : public SamplingIntegratorGPU<DirectLightingGPUIntegrator> {
public:
	DirectLightingGPUIntegrator();

    virtual RenderResult render(const Scene& scene, const CameraObject& camera, FilmObject& film) override;

    __device__
	static Spectrum renderRay(const SceneHandle& scene, const Ray& ray,SamplerObject& sampler){
        IntersectionResult intersection;
        scene.intersect(intersection,ray);

        
        if(!intersection.intersected){
            return scene.getEnvironmentMap().EnvironmentMap::evaluateRay(ray);
        }
        
        
        Spectrum result = make_float3(0,0,0);


        const Primitive* prim = intersection.primitive;

        Ray exitantRay = {intersection.position,ray.direction*-1};

        for (int i = 0; i < scene.lightsCount;++i) {
            const LightObject& light = scene.lights[i];
            Ray rayToLight;
            float probability;
            float2 randomSource = sampler.rand2();

            VisibilityTest visibilityTest;
            visibilityTest.sourceGeometry = prim->shape.getID();


            Spectrum incident = light.sampleRayToPoint(intersection.position, randomSource, probability, rayToLight,visibilityTest);

            if(scene.testVisibility(visibilityTest) && dot(rayToLight.direction, intersection.normal) > 0){
                result += prim->material.eval(rayToLight,incident,exitantRay,intersection);
            }
        }
        return result;
    }
    
};