// 셰이더에 필요한 공용 정의문을 모아둔 hlsli 파일을 포함
#include "Engine_Shader_Defines.hlsli"

// Engine_Shader_Defines.hlsli의 공용 함수
// 깊이 픽셀을 월드 좌표로 변환
float3 ReconstructWorldPos(float2 vUV)
{
    float4 vDepth = g_DepthTexture.Sample(Point_Clamp_Sampler, vUV);
    float fDepth = vDepth.x;
    float fViewZ = vDepth.y * g_vCamRange.y;

    float4 vClip;
    vClip.x = vUV.x * 2.f - 1.f;
    vClip.y = vUV.y * -2.f + 1.f;
    vClip.z = fDepth;
    vClip.w = 1.f;

    vClip *= fViewZ;
    float4 vView = mul(vClip, g_ProjMatrixInv);
    float3 vWorldP = mul(vView, g_ViewMatrixInv).xyz;
    
    return vWorldP;
}

// 변수 선언
matrix g_WorldMatrix, g_ViewMatrix, g_ProjMatrix;
matrix g_WorldMatrixInv, g_ViewMatrixInv, g_ProjMatrixInv;

Texture2D g_DiffuseTexture;
Texture2D g_NormalTexture;
Texture2D g_DepthTexture;
Texture2D g_DissolveTexture;
Texture2D g_MaskTexture;

vector g_vBoxSize;

float g_fBright;

bool g_bUseMotionTexture;
bool g_bUseMaskTexture;

bool g_bUseAtlas_Diffuse;
bool g_bUseAtlas_Motion;
bool g_bUseAtlas_Mask;

bool g_bUseColor;
float4 g_vColor;

bool g_bIsPlaying;

float g_fElapsedTime;
float g_fStartDelay;
float g_fLifeTime;
bool g_bIsLoop;

int g_iUVIndex;
bool g_bUseAtlas;
int g_iNumUVCols;
int g_iNumUVRows;

bool g_bUseUVAnimation;
float g_fUVFrameSpeed;

float g_fDistortStrength;
float g_fDistortSpeed;

float4 g_vCamPosition;
float2 g_vCamRange;

struct VS_IN
{
    float3 vPosition : POSITION; // [-0.5, 0.5] 로컬 큐브 -> 월드 변환
    float3 vTexcoord : TEXCOORD0; // 로컬 큐브
};

struct VS_OUT
{
    float4 vPosition : SV_POSITION; // 클립 공간에서의 위치
    float3 vLocalPos : TEXCOORD0; // 박스 로컬 검사 좌표
    float4 vClipPos : TEXCOORD1; // PS에서 UV 계산용으로 클립 위치 그대로
};

// Vertex Shader
VS_OUT VS_MAIN(VS_IN In)
{
    VS_OUT Out = (VS_OUT) 0;
    
    // 월드 변환
    float4 vWorldPos = mul(float4(In.vPosition, 1.f), g_WorldMatrix);
    // 뷰, 투영 변환
    float4 vClipPos = mul(vWorldPos, mul(g_ViewMatrix, g_ProjMatrix));

    Out.vPosition = vClipPos;
    Out.vClipPos = vClipPos; // PS에서 화면 UV로 복원 예정
    Out.vLocalPos = In.vTexcoord; // 로컬 박스 좌표
    
    return Out;
}

struct PS_IN
{
    float4 vPosition : SV_POSITION;
    float3 vLocalPos : TEXCOORD0;
    float4 vClipPos : TEXCOORD1;
};

struct PS_OUT
{
    float4 vColor : SV_TARGET0;
};

// Pixel Shader
// 데칼 셰이더 中 자상 데칼 셰이더
PS_OUT PS_DECAL_SLASH(PS_IN In)
{
    PS_OUT Out;
    
    // 화면 UV 복원
    float2 vScreenUV = In.vClipPos.xy / In.vClipPos.w * float2(0.5f, -0.5f) + 0.5f;
    // 깊이로부터 월드 위치 재구성
    float3 vWorldPos = ReconstructWorldPos(vScreenUV);
    // 데칼 박스 로컬 좌표
    float4 vLocalPos = mul(float4(vWorldPos, 1.f), g_WorldMatrixInv);
    // 박스 절반 크기
    float3 vHalfSize = g_vBoxSize * 0.5f;

    // 박스 범위 밖이면 버림
    if (any(abs(vLocalPos.xyz) > vHalfSize))
        discard;

    // 씬 픽셀 노말 가져와서 가중치 계산
    float3 vNormal = normalize(g_NormalTexture.Sample(Point_Clamp_Sampler, vScreenUV).rgb * 2.0f - 1.0f);
    float3 vAbs = abs(vNormal);
    float fInvSum = 1.f / (vAbs.x + vAbs.y + vAbs.z + 1e-6f);
    float3 vWeight = vAbs * fInvSum;
    
    // 각 축별 UV 계산(세로 뒤집기)
    float2 UVAxis[3];
    UVAxis[0] = float2((vLocalPos.z + vHalfSize.z) / g_vBoxSize.z,
                        1.f - ((vLocalPos.y + vHalfSize.y) / g_vBoxSize.y));
    UVAxis[1] = float2((vLocalPos.x + vHalfSize.x) / g_vBoxSize.x,
                        1.f - ((vLocalPos.z + vHalfSize.z) / g_vBoxSize.z));
    UVAxis[2] = float2((vLocalPos.x + vHalfSize.x) / g_vBoxSize.x,
                        1.f - ((vLocalPos.y + vHalfSize.y) / g_vBoxSize.y));

    // 가장 가중치 큰 축 인덱스 선정
    int iAxis = 0;
    if (vWeight.y > vWeight.x && vWeight.y > vWeight.z)
        iAxis = 1;
    else if (vWeight.z > vWeight.x && vWeight.z > vWeight.y)
        iAxis = 2;

    // 최종 UV
    float2 vFinalUV = UVAxis[iAxis];
    
    // 샘플링
    float4 vColorX = g_DiffuseTexture.Sample(Linear_Clamp_Sampler, UVAxis[iAxis]);
    float4 vColorY = g_DiffuseTexture.Sample(Linear_Clamp_Sampler, UVAxis[iAxis]);
    float4 vColorZ = g_DiffuseTexture.Sample(Linear_Clamp_Sampler, UVAxis[iAxis]);

    float4 vColor;
    
    // 최대 가중치 축만 선택
    if (vWeight.x > vWeight.y && vWeight.x > vWeight.z)
        vColor = vColorX;
    else if (vWeight.y > vWeight.x && vWeight.y > vWeight.z)
        vColor = vColorY;
    else
        vColor = vColorZ;
    
    float fMask = g_MaskTexture.Sample(LinearSampler, UVAxis[iAxis]).r;

    vColor *= fMask;
    
    vColor.rgb *= g_vColor.rgb * g_fBright;
    vColor.a *= g_vColor.a;
    
    float fLifeRatio = saturate(g_fElapsedTime / g_fLifeTime);

    float fFadeAlpha = saturate(1.f - fLifeRatio);
    vColor.a *= fFadeAlpha;
    
    Out.vColor = vColor;
    
    return Out;
}

// ...

technique11 DefaultTechnique
{
    pass DecalSlash
    {
        SetRasterizerState(RS_Cull_None);
        SetDepthStencilState(DSS_NonWriteZ, 0);
        SetBlendState(BS_Blend, float4(0.f, 0.f, 0.f, 0.f), 0xffffffff);
    
        VertexShader = compile vs_5_0 VS_MAIN();
        GeometryShader = NULL;
        PixelShader = compile ps_5_0 PS_DECAL_SLASH();
    }

    // ...
}