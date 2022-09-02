# RootSignature

RootSignature 映射到如下概念上：

- vulkan: VkPipelineLayout + VkDescriptorSetLayout
- D3D12: RootSignature
- metal: ArgumentDescriptor

CGPU 的 RootSignature 创建非常自动化，只需要传入以下数据:

- pipeline shaders: vs, gs, hs, ps, cs...
- static samplers: 名字、个数以及 Sampler 对象
- push constants: 名字以及个数

大量的工作在后端完成，以确保在统一的前端概念下最优化的实现。后端会处理如下任务以创建出真实的后端结构：

- 通过 shader 反射来自动获取到着色器参数表；
- 合并不同 pipeline shader 的参数表，以自动创建出最优 visibility 的绑定表；
- 反射出的绑定表会被存储到 RootSignature 对象头中，帮助上层应用程序以可编程的方式实现自动化且高效的 DescriptorSet 创建以及参数更新。

得益于完全自动的反射流程，CGPU 可以轻松地在不同的平台变换参数绑定表的布局并使用名字更新它们，而 Host 程序完全无需为 shader 程序的参数表变化做出任何的应对。比如我们可以在 shader 中这样写：

``` hlsl
// d3d12:   0|  tex  |
//          1|sampler|          d3d12的 static sampler 必须在单独的表上
// vk:      0|  tex  |sampler|  而 vulkan 不需要这样，所以可以节省一个表行
[[vk::binding(0, 0)]]
Texture2D<float4> sampled_texture : register(t0, space0);
[[vk::binding(1, 0)]]
SamplerState texture_sampler : register(s0, space1);
```

而在 Host 程序中如此更新它们:

``` cpp
// 以静态采样器模式绑定
root_sig_desc.static_samplers = {"texture_sampler"};
auto root_sig = cgpu_create_root_signature(device, &root_sig_desc);
// ...
// 在 descriptor set 上更新纹理
CGPUDescriptorData arguments[1];
arguments[0].name = "sampled_texture";
arguments[0].count = 1;
arguments[0].textures = &texture;
cgpu_update_descriptor_set(desc_set, arguments, 1);
```

这将 descriptor set 的布局完全交给了 shader 的编写者，而无需在 Host 程序上做出任何修改。

得益于运行时 shader 反射，CGPU的 RootSignature 还实现了 visibility 的最大优化。倘若一个绑定只出现在 pixel-shader-stage，那么生成的 RootSignature 就会给该绑定槽位添加 VISIBILITY_PIXEL_SHADER_ONLY，以最大化管线的性能。

``` hlsl
// vs
[[vk::binding(0, 0)]]
Texture2D<float4> sampled_texture : register(t0, space0);
// ps
[[vk::binding(0, 0)]]
Texture2D<float4> sampled_texture : register(t0, space0);
// VISIBILITY_VERTEX_SHADER | VISIBILITY_PIXEL_SHADER
// HULL SHADER / DOMAIN SHADER... INVISIBLE

```

同样地我们也最大程度地支持 overlap。通过在不同阶段对同一个绑定槽位给予不同的名字，就可以在不同的 shader 阶段复用槽位并分别对它们进行更新。

``` hlsl
// vs
[[vk::binding(0, 0)]]
Texture2D<float4> sampled_texture : register(t0, space0);
// VISIBILITY_VERTEX_SHADER
// ps
[[vk::binding(0, 0)]]
Texture2D<float4> sampled_texture2 : register(t0, space0);
// VISIBILITY_PIXEL_SHADER 

```

# RootSignaturePool

根签名池通过检查绑定表的布局来辅助用户完成自动地 RootSignature 复用。观察一下两个 shader 绑定：

``` hlsl
// vs0
ConstantBuffer buffer0 : register(c0, space0);
// ps0
Texture2D<float4> sampled_texture0 : register(t0, space0);
SamplerState texture_sampler0 : register(s0, space1);

// vs1
ConstantBuffer buffer1 : register(c0, space0);
// ps1
Texture2D<float4> sampled_texture1 : register(t0, space0);
SamplerState texture_sampler1 : register(s0, space1);
```

这两组 shader 拥有完全一致的参数布局，完全可以共享一个 RootSignature。因此 CGPU 提供了 RootSignaturePool。

``` cpp
CGPURootSignaturePoolDescriptor pool_desc = {};
pool_desc.name = "RSPool";
auto pool = cgpu_create_root_signature_pool(device, &pool_desc);
// ...
CGPURootSignatureDescriptor rs_desc = {...};
rs_desc.pool = pool;
// ...
cgpu_free_root_signature_pool(pool);
```

只需要在创建 RootSignature 时传入 Pool，即可自动完成上述复用。CGPU 会扫描 Pool 中 RootSignature 的特征并尝试匹配已存的合适根签名，当匹配失败时才会创建新的 RootSignature。

此外，在使用 pool 创建 RootSignature 时，create/free_root_signature 会切换成 RC 模式。每次被复用，都会为原始的 RootSignature 添加 RC 计数。在 RC 计数为 0 时，后端的 API 资源会被真正销毁。

使用 pool 复用 RootSignature 不仅能减少 GPU 上的切换，更能在 CPU 端减少序列化以及销毁 RST 的时间。但是永远不要忘记调用 free_root_signature，否则会产生 RST 对象泄露。

# TODO：绑定表合并提醒

通过分析全局的 RootSignature 绑定表，筛选出可以重排合并的项，辅助用户修改 shader 绑定达到最少 RST 的目的。

``` hlsl
// ps0
[[vk::binding(0, 0)]]
Texture2D<float4> sampled_texture : register(t0, space0);
[[vk::binding(1, 0)]]
SamplerState texture_sampler : register(s0, space1);

// ps1
[[vk::binding(0, 0)]]
SamplerState texture_sampler : register(s0, space1);
[[vk::binding(1, 0)]]
Texture2D<float4> sampled_texture : register(t0, space0);
// 颠倒 ps1 的采样器和纹理位置即可合并 RootSignature
```