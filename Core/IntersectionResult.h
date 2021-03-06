#pragma once

#include "../Utils/GpuCommons.h"
#include "../Utils/MathsCommons.h"
#include "../BSDFs/BSDFObject.h"

class Primitive;

struct IntersectionResult{
    bool intersected = false;
    float distance;
    float3 position;
    float3 normal;
    float2 textureCoordinates;
    const Primitive* primitive;
    BSDFObject bsdf;

    __device__
    void findBSDF();

    // Design decision:
    // the tangents are re-computed everytime they're used. This is slightly slower, but saves a lot of memory
    __device__
    void findTangents(float3& tangent0, float3& tangent1) const {
        buildCoordinateSystem(normal, tangent0, tangent1);
    }

    __device__ 
    float3 worldToLocal(const float3& v) const{
        float3 tangent0, tangent1;
        findTangents(tangent0, tangent1);
        return worldToLocal(v, tangent0, tangent1);
    }

    __device__
    float3 localToWorld(const float3& v) const{
        float3 tangent0, tangent1;
        findTangents(tangent0, tangent1);
        return localToWorld(v, tangent0, tangent1);
    }

    __device__
    float3 worldToLocal(const float3& v, const float3& tangent0, const float3& tangent1) const {
        glm::mat3 mat = buildMat3UsingVecsAsRows(tangent0, tangent1, normal);
        return to_float3(mat * to_vec3(v));
    }

    __device__
    float3 localToWorld(const float3& v, const float3& tangent0, const float3& tangent1) const {
        glm::mat3 mat = buildMat3UsingVecsAsCols(tangent0, tangent1, normal);
        return to_float3(mat * to_vec3(v));
    }

};