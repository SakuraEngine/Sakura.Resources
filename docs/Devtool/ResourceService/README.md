# Resource Pipeline in Sakura

## Introduce

在 Sakura 中，我们对资源管线做了严格定义，将数据拆解为了三个阶段：

* Asset，资产 - 用户侧的文件，带有大量面向编辑的元信息，举例来说：源代码，psd 文件，ma 文件等等都属于 Asset。
* RawResource - 资源数据，Asset 去除所有编辑元信息之后的全量数据，举例来说：代码编译到IR，ppm 格式的图片等都属于 RawResource
* Resource - 烘焙过后的资源数据，是 RawResource 经过平台相关的处理和优化之后最终的数据格式，举例来说：IR编译为汇编并进行优化，图片压缩为 DXT 之类的显卡压缩格式都属于 Resource

Sakura Devtool 包含了一系列组件以提供 Asset 到 Resource 的转换。整体上，Sakura 遵循了 non-destructive 的设计目标，最大程度上和外部工具进行集成。

> [Resource](Runtime/Resource/README.md) 

## 导入

**导入是指创建 asset 到 resource 的映射的过程**，作为 non-destructive 的管线流程，Sakura 不会直接将 asset 文件转化为 resource 文件，而是会记录一个他们之间的映射，这个映射作为被保存在一个独立的 **meta 文件**中。

**这意味着每个 resource 都存在一个 meta 文件存储其信息**，内部格式为 json，文件命名一般为 name.type.meta 比如 floor.mesh.meta；上文提到的映射则记录在的其 import section 里，meta 还可以拥有其他 section 来描述进一步的烘焙行为。

**值得注意的是，这个 meta 文件也可以视为一个新的 asset，Sakura 中称作 meta asset**，这意味着可以在其之上建立次级映射。

对于用户界面，在导入一个 asset 的时候，工具会展开 asset 里面可以导入的所有 resource，用户选取 resource 并对映射的参数进行配置，然后工具会创建对应的 meta asset，完成一次导入。

映射内容示例：

* asset 引用
* 内容 id
* 轴转换

## 提取

**提取是指把原 asset 的一部分转换为新 asset 的过程**，对于一些复合型的 asset，可能存在部分被其他工具 asset 覆盖的功能（比如 Hierachy 编辑），Sakura 可以对这部分进行提取，转换并创建出相应的工具 asset 以供用户在对应的工具直接编辑，通过这个步骤扩展原资产的部分能力（比如从 fbx 提取出 prefab 以供 prefab 编辑器使用，并在 prefab 编辑器中插入粒子特效）。

**提取过后产生的新 asset 可能和原 asset 失去同步**，所以这个操作需要适当使用。

**提取行为会被记录在 asset 的 meta 中，使得其他 resource 的引用能正确重定向**，比如提取了 gltf 的一个材质定义，从 gltf 导入的 mesh 也会正确应用新的材质而不是原 gltf 的材质。

## 烘焙

**烘焙是指从 asset 到 resource 的处理的过程**，这个过程会读取 meta asset 和全局设置（平台设置，质量设置等），根据 resource 之间的依赖关系图递归的处理 resource，并建立 resource 之间的运行时依赖关系。


基于 Asset 和 Resource 类型的多对一关系 - asset 中的 png，tga 等都对应 resource 中的 texture。烘焙被分为两个步骤：导入和烘焙，由导入代码从 asset 中提取出 RawResource，然后再由烘焙代码把 RawResource 中处理为最终的 Resource。

### 实现细节

烘焙器是一个独立的的可执行程序服务，由动态库形式的烘焙插件扩展。每个烘焙请求产生一个烘焙任务进入线程池调度（或发给子进程执行），烘焙过程中可以再产生新的请求串联其他烘焙插件。

烘焙器存在一个守护进程，由守护进程保护烘焙器的顺利运行 - 在烘焙器崩溃的时候负责重新拉起烘焙器，烘焙器会尽量跳过导致崩溃的资源并记录日志。

烘焙器是单例服务，可以同时支撑多个工程实例。

烘焙器可以开启 Worker 模式，执行远端的烘焙任务。

烘焙器同时支持全量烘焙、增量烘焙和惰性烘焙，并且支持和 resource 缓存服务。

具体实现见：https://www.gdcvault.com/play/1025264/The-Asset-Build-System-of

### 缓存

TODO


