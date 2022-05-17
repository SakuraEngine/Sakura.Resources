# Resource in Sakura

## Introduce

在 Sakura 中，我们对资源管线做了严格定义，将数据拆解为了三个阶段：

* Asset，资产 - 用户侧的文件，带有大量面向编辑的元信息，举例来说：源代码，psd 文件，ma 文件等等都属于 Asset。
* RawResource - 资源数据，Asset 去除所有编辑元信息之后的全量数据，举例来说：代码编译到IR，ppm 格式的图片等都属于 RawResource
* Resource - 烘焙过后的资源数据，是 RawResource 经过平台相关的处理和优化之后最终的数据格式，举例来说：IR编译为汇编并进行优化，图片压缩为 DXT 之类的显卡压缩格式都属于 Resource

Sakura Runtime 只对 Resource 进行装载，而完全隔离 Asset 和 RawResource 的细节，这意味着 Sakura Runtime 直接在目标环境中运行，尽量去除开发版和发布版的差别。
>[ResourceService](Devtool/ResourceService/README.md)

## 资源装载

### 原理

首先是资源引用，考虑到游戏项目资源的高频流动性（一个情景是，导入一个大型素材包进行使用，然后在场景搭建完成之后把没用到的素材清理掉，并整理目录），Sakura 使用了 GUID 作为资源的引用以增强依赖的稳定性，作为代价，依赖的可读性会损失。

在装载方面，Sakura 把资源的状态显式的分为了多个阶段：

1. 资源发现 - 从资源 GUID 映射到物理路径、资源类型和所在的虚拟文件系统
2. 资源IO - 从资源所在的虚拟文件系统读取资源的数据到内存
3. 资源载入 - 从读取完成的内存中反序列化出资源具体数据，同时发起依赖资源的装载
4. 资源安装 - 实例化依赖的引用，正式初始化资源，比如上载数据到显卡

为了提高响应速度和性能，Sakura 中以上阶段全部进行了异步化处理，并为每个阶段准备了合理的异步手段：对于 IO 型任务，Sakura 提供了 [IO Service](Runtime/IO/README.md)；而对于运算密集型任务，Sakura 提供了基于 Fiber 的 [TaskScheduler]()。

同时游戏作为高动态的应用，资源的请求也是高动态的，会存在资源还没有加载完就不需要了的情况（玩家快速传送），通过切分阶段，Sakura 能够在每个阶段及时的进行 Cancel 响应，减少资源加载峰值并提高吞吐量。

### 实现

资源引用使用了一个 ResourceHandle 的结构，是一个将 GUID 和指针重叠在同一份内存上的 128 位智能指针。

资源装载阶段之间的调度由 ResourceSystem 自动处理，而阶段的具体行为由 ResourceFactory 定义，提供了如下两个定义点：

* Load / UpdateLoad - 对应 2，3 阶段，即资源IO和载入
* Install / UpdateInstall，对应 4 阶段，即资源安装

资源装载关系使用了三段式的结构：

1. ResourceSystem 调度状态，调用 ResourceFactory 收集异步任务
2. 合批收集的异步任务，发起异步工作
3. ResourceSystem 再次调用 ResourceFactory，更新状态

