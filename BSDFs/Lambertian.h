#pragma once
#include "../Core/BSDF.h"
#include "../Utils/MathsCommons.h"
#include "../Utils/RandomUtils.h"

class LambertianBSDF: public BSDF{
public:
    Spectrum baseColor;


	__host__ __device__
	LambertianBSDF(){}

    __host__ __device__
    LambertianBSDF(const Spectrum& baseColor_):baseColor(baseColor_){}

    __device__
    virtual Spectrum eval(const float3& incident, const float3& exitant) const override {
        if (!sameHemisphere(incident, exitant)) {
            return make_float3(0, 0, 0);
        }
        return baseColor / M_PI;
    }

    __device__
    virtual Spectrum sample(float2 randomSource, float3& incidentOutput, const float3& exitant, float* probabilityOutput) const {
        

        incidentOutput = cosineSampleHemisphere(randomSource);
        *probabilityOutput = LambertianBSDF::pdf(incidentOutput,exitant);

        if (exitant.z < 0) {
            incidentOutput.z *= -1;
        }

        return LambertianBSDF::eval(incidentOutput, exitant);

    }

    __device__
    virtual float pdf(const float3& incident, const float3& exitant) const {
        return cosineSampleHemispherePdf(incident);
    }

};

