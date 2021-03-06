#pragma once
#include "../Core/BSDF.h"


#include "../Utils/MathsCommons.h"
#include "../Utils/RandomUtils.h"



class MicrofacetBSDF: public BSDF{
public:
    Spectrum reflectionColor;
    Spectrum transmissionColor;

    GGX distribution;
    Fresnel fresnel;

    float aboveIOR;
    float belowIOR;

    bool hasTransmission;

	__host__ __device__
	MicrofacetBSDF(){}

    __host__ __device__
    MicrofacetBSDF(const Spectrum& reflectionColor_,const GGX& distribution_,const Fresnel& fresnel_, 
    bool hasTransmission_ = false, const Spectrum& transmissionColor_ = make_float3(0,0,0), float aboveIOR_ = 1.5f, float belowIOR_ = 1.5f):
    reflectionColor(reflectionColor_),distribution(distribution_),fresnel(fresnel_),
    hasTransmission(hasTransmission_), transmissionColor(transmissionColor_),aboveIOR(aboveIOR_),belowIOR(belowIOR_)
    {

    }


    __device__
    Spectrum evalReflection(const float3& incident, const float3& exitant) const{
        if(!sameHemisphere(incident,exitant)){
            return make_float3(0,0,0);
        }
        float cosThetaO = abs(cosZenith(exitant));
        float cosThetaI = abs(cosZenith(incident));

        float3 halfVec = incident + exitant; 

        if (cosThetaI == 0 || cosThetaO == 0) return make_float3(0,0,0); 
        if (halfVec.x == 0 && halfVec.y == 0 && halfVec.z == 0) return make_float3(0,0,0); 
        
        halfVec = normalize(halfVec); 
        auto F = fresnel.eval(dot(exitant, halfVec)); 

        return reflectionColor * distribution.D(halfVec) * distribution.G(exitant, incident)*F/ (4 * cosThetaI * cosThetaO);
    }

    __device__
    Spectrum evalTransmission(const float3& incident, const float3& exitant) const {
        if(sameHemisphere(incident,exitant)){
            return make_float3(0,0,0);
        }
        float cosThetaO = abs(cosZenith(exitant));
        float cosThetaI = abs(cosZenith(incident));

        if (cosThetaI == 0 || cosThetaO == 0) return make_float3(0,0,0); 

        float eta = cosZenith(exitant) > 0 ?  (aboveIOR / belowIOR) : (belowIOR / aboveIOR);
        float3 halfVec = normalize(exitant + incident * eta);
        if (halfVec.z < 0) halfVec = -halfVec;
        
        // Same side?
        if (dot(exitant, halfVec) * dot(incident, halfVec) > 0) return make_float3(0,0,0); 

        auto F = fresnel.eval(dot(exitant, halfVec)); 

        float sqrtDenom = dot(exitant, halfVec) + eta * dot(incident, halfVec);
        
        return (make_float3(1,1,1) - F) * transmissionColor *
                abs(distribution.D(halfVec) * distribution.G(exitant, incident) * eta * eta *
                        abs(dot(incident, halfVec)) * abs(dot(exitant, halfVec))  /
                        (cosThetaI * cosThetaO * sqrtDenom * sqrtDenom));
    }

    __device__
    virtual Spectrum eval(const float3& incident, const float3& exitant) const override {
        if (!hasTransmission) {
            return evalReflection(incident, exitant);
        }
        if(sameHemisphere(incident,exitant)){
            return evalReflection(incident,exitant);
        }
        else{
            return evalTransmission(incident,exitant);
        }
    }


    __device__
    Spectrum sampleReflection(float2 randomSource, float3& incidentOutput, const float3& exitant, float* probabilityOutput) const {
        
        float3 halfVec = distribution.sample(randomSource,exitant);
        incidentOutput = reflectF(exitant, halfVec);

        *probabilityOutput = pdfReflection(incidentOutput,exitant,halfVec);

        return evalReflection(incidentOutput, exitant);
    }

    __device__
    float pdfReflection(const float3& incident, const float3& exitant)const{
        float3 halfVec = normalize(incident+exitant);
        return pdfReflection(incident,exitant,halfVec);
    }

    __device__
    float pdfReflection(const float3& incident, const float3& exitant, const float3& halfVec)const{
        return  distribution.pdf(halfVec,exitant) / (4.f*dot(exitant,halfVec));
    }

    __device__
    Spectrum sampleTransmission(float2 randomSource, float3& incidentOutput, const float3& exitant, float* probabilityOutput) const {
        
        if (exitant.z == 0){
            SIGNAL_ERROR("exitant z == 0\n");   
        }
        float3 halfVec = distribution.sample(randomSource,exitant);
        //(wo, wh) < 0) return 0.;  // Should be rare

        float eta = cosZenith(exitant) > 0 ?  (aboveIOR / belowIOR): (belowIOR / aboveIOR);
        if (!computeRefraction(exitant, halfVec, eta, incidentOutput)){
            return make_float3(0,0,0);
        } 

        *probabilityOutput = pdfTransmission(incidentOutput,exitant);

        return evalTransmission(incidentOutput,exitant);
    }

    __device__
    float pdfTransmission(const float3& incident,const float3& exitant)const{
        
        float eta = cosZenith(exitant) > 0 ? (aboveIOR / belowIOR) : (belowIOR / aboveIOR);
        float3 halfVec = normalize(exitant + incident * eta);
        
        return pdfTransmission(incident,exitant,halfVec,eta);
    }

    __device__
    float pdfTransmission(const float3& incident, const float3& exitant, const float3& halfVec, float eta)const{

        //printf("%f %f %f    vs   %f %f %f.   in: %f %f %f,   out:%f %f %f, eta:%f vs %f\n", XYZ(halfVec), XYZ(halfVec_),XYZ(incident),XYZ(exitant),eta,eta_);

        if (sameHemisphere(incident,exitant)) return 0;

        if (dot(exitant, halfVec) * dot(incident, halfVec) > 0) return 0; 

        // Compute change of variables _dwh\_dwi_ for microfacet transmission
        float sqrtDenom = dot(exitant, halfVec) + eta * dot(incident, halfVec);
        float dwh_dwi =
            abs((eta * eta * dot(incident, halfVec)) / (sqrtDenom * sqrtDenom));
        return distribution.pdf(halfVec,exitant) * dwh_dwi;
    }

    __device__
    float getSampleReflectionProbability(const float3& exitant)const{
        float p = fresnel.eval(abs(cosZenith(exitant))).x;
        if (isAllZero(reflectionColor)) {
            p = 0;
        }
        else if (isAllZero(transmissionColor)) {
            p = 1;
        }
        return p;
    }
    

    __device__
    virtual Spectrum sample(float2 randomSource, float3& incidentOutput, const float3& exitant, float* probabilityOutput) const {
        if(!hasTransmission){
            return sampleReflection(randomSource,incidentOutput,exitant,probabilityOutput);
        }

        float sampleReflectionProbability = getSampleReflectionProbability(exitant);

        bool useBRDF = randomSource.x < sampleReflectionProbability;
        if(useBRDF){
            randomSource.x = randomSource.x*(1.f/sampleReflectionProbability);
            float3 result = sampleReflection(randomSource,incidentOutput,exitant,probabilityOutput);
            *probabilityOutput *= sampleReflectionProbability;
            return result;
        }
        else{
            randomSource.x = (randomSource.x-sampleReflectionProbability)*(1.f/(1.f-sampleReflectionProbability));
            float3 result = sampleTransmission(randomSource, incidentOutput, exitant, probabilityOutput);
            *probabilityOutput *= 1.f - sampleReflectionProbability;
            return result;
        }
    }

    __device__
    virtual float pdf(const float3& incident, const float3& exitant) const {
        if (!hasTransmission) {
            return pdfReflection(incident,exitant);
        }
        else if(sameHemisphere(incident,exitant)){
            return getSampleReflectionProbability(exitant) * pdfReflection(incident,exitant);
        }
        else{
            return (1.f-getSampleReflectionProbability(exitant)) * pdfTransmission(incident,exitant);
        }
    }

    __device__
    virtual bool isAlmostDelta() const override {
        return distribution.isAlmostDelta();
    };

};



