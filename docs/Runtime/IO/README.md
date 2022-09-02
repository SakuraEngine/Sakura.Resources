# Introduce

游戏引擎的 I/O 是一个很有特色的领域，具有一定的特殊性。和现在讨论较热的网络异步IO（典型是 ASIO ）相比，基本就是蓝脸道尔顿和红脸关公：看起来好像是那么一回事（指都要处理并发提交和任务异步），但是其实完全不是那么一回事。简单来讲，有以下几个差异：

## I/O的硬件原理截然不同

网络 I/O 一般走的是**网卡**。网卡天生就是基于流且支持特别多路 datapath 的。硬件设计上着重强化对数据的流送和小块流的缓存。

但是游戏引擎的 I/O 多数走的是**硬盘**，硬盘的数据通道是有限的（硬件上对应内存通道和磁盘磁头）。

## I/O的系统基础截然不同

网络 I/O 使用 Pipe 等本质异步的软件概念，在API上体现为 io_uring 和 IOCP 等异步端口式模型。要打开足够多的端口，才能处理足够多的请求。

游戏引擎的I/O，在**单文件I/O速度优先**、多I/O任务优先级需要排序等等需求的驱动下，必须使用FileRead或者FileMap这种文件式的同步模型。要在一个通道上**对单文件进行足够快的读写**，才能保证快速的场景显示。

对于硬盘或是内存块这种设备，要想实现带宽利用率最大化，必须**不能使用Pipe**等异步端口模型。因为操作系统**完全无法预测你的异步请求尺寸**，这会导致向DMA发起合批请求时效率非常低下。I/O对准DMA的请求，必须是**同步的、固定尺寸的**。

## I/O的规模截然不同

网络流里面的数据，大都是各种请求和小数据包之类的零散内容，并且在时间轴上不稳定，即天生异步。

游戏中对准静态文件系统的I/O，一般都是：

- **有序的** 场景I/O都是从相机的近处开始，向远处排序，以保证先刷新眼前的事物。资源依赖也决定了一定的加载顺序，这些都是网络I/O不存在的；
- **大的** 文件的尺寸都不小。图片，网格等等都是单节点数十MB的尺寸，而不是几十Byte的请求包；
- **没有那么多的** 单一的加载队列，最多也就有数十个文件在排队。这和网络I/O是差别甚大的。

## I/O Service

根据上面网络I/O的特性，就造就了ASIO之类使用 io_uring / iocp 等异步传输API的范式或者库。很多同学可能觉得这种异步 I/O 代表着高并发以及高速度，但是看完上面这些内容你肯定已经知道，在游戏引擎的用例中它们显然是不适用的。

游戏引擎需要尽可能高速度的单文件同步 I/O，以及对 I/O 进行排序的功能。当然 I/O 的请求需要是异步的，我们肯定不能让事务线程在那里等待I/O返回。这就需要把阻滞的 I/O Invoke 移交到独立的线程上去，以完成异步请求的目的。我们需要自己调度线程来实现这点，所以这里就又引出了 I/O Service 的概念（当然可以加一个硬件专门 I/O，CPU 对那个硬件提交指令并等待信号量，是有这么干的）。

# 保证高速度的同步I/O

同步I/O有两种常见的形式：FileMap 和 FileRead。它们在不同的平台上有性能差异，但单纯考虑读取，它们是可以互相兼容替代的，所以在合适的平台选用合适的就可以了。但是每个平台的 FileMap/Read 都有自己的API，要保证速度地（0拷贝...）集成起来是个技术活。

[LLFIO（P1031)](https://github.com/ned14/llfio)是一个对准C++标准库的 LowLevelFileIO 库，对于常见的平台都有支持（不常见的平台一般都有自己的高速硬件或者系统API。。。。），保证了0拷贝等性能热点。

此外，它不是对 Win32 API 的浅层优化那么简单，而是直接使用了一些系统 kernel 的 PrivateAPI 进行实现的。它也暴露了很多可以提升磁盘同步I/O的选项：

![llfio-flags](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/llfio-flags.png)

使用它实现一套[VFS API](https://github.com/SakuraEngine/Sakura.Runtime/blob/main/src/platform/llfio/llfio_vfs.cpp)即可。

# I/O Service

在常见的平台上，我们使用线程来实现 ioService。我们首先分析一下游戏中常见的用例，大致思考出 ioService 的接口和实现办法。游戏中的 I/O ，流程是以下这样的：

- 各个线程需要某个文件资源，因此发起 I/O；
- 非常多的 I/O 事务形成一个队列，ioService 选择其中优先级最高的，开始读取；
- 完成读取后，通过更新信号量来指示其他线程上的事务，提示 I/O 已经完成；
- 检查到 I/O 完成的事务对资源进行使用。

可以看到核心是任务队列和优先级排序。此外，为了保证线程不产生性能问题，需要让ioService线程在没有任务的时候进行睡眠。因此引出如下[接口](https://github.com/SakuraEngine/Sakura.Runtime/blob/main/include/utils/io.hpp)细节：

- 任务队列 游戏的I/O很少，所以大部分情况上锁是最快的。但是我们在游戏中使用纤程，会有潜在的死锁感染问题。所以一个写无锁的接口是必要的；
- 优先级排序 以任务的优先级为准进行排序。排序可以是 stable 的、partial 的、关闭的，甚至是自定义的；
- 取消 很多 I/O 任务是要能够尝试取消的。比如你穿越了地图的四叉树节点，那么之前在队列中的、较远的节点中的场景物体加载必须尽可能地被取消；
- 可缩放睡眠 睡眠的时间不能是固定的，需要是可以进行设置的。在游戏内，一帧内提交的任务可以视作一批，因此 sleep time 和 frame time 是严格挂钩的。例如30帧的游戏，那么睡眠时间就是33 ms。在资源烘培管线上，则是需要应对大量的文件请求。那么睡眠的时间需要是较短的，甚至是可以从外部进行唤醒的。

# 细节和实现

## 请求

请求可以设置优先级用于排序。请求内有一个原子量，在任务状态更新时，ioService 会设置这个原子量来提示外部事务：

![io-status](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/io-status.jpg)

ioService 是可以支持有锁、无锁模式的，这个模式也可以随时切换。原理非常简单：添加一个无锁队列专门用于接口的写操作，在执行排序之前把无锁队列里的任务都pop到普通的队列去。

## 取消

取消有两种模式：

- **立即** 有锁模式下可以直接上锁，用当前线程查找是否有要取消的任务存在，存在即取消，且马上返回结果；
- **延迟** 延迟取消只向 I/O 线程提交申请，在 I/O 线程进行排序之前会进行查找和取消。不能返回结果也没办法预测是否成功，只能在晚些时候检查 request 的状态来判断是否被 cancel。

## 睡眠时间和模式

睡眠是影响性能表现的一个重要因素。睡的不够，那线程就一直活跃，造成性能降低。睡的太多，I/O 任务堆积，外面的事务也没法向前推进，就造成任务堆积：

![pile-up-with-sleep](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/pile-up-with-sleep.jpg)

比较有趣且值得一提的是，我们的 fiber 任务系统完全可以顶住上面的任务堆积压力。即使有几千个 fiber，也并没有因为轮询切换产生一丁点的性能问题。这是 thread based 的任务系统无法做到的。

睡眠的模式分两种：

- 使用系统的 Sleep：直接睡眠固定的毫秒数，稳定让出线程，适合用在游戏内逐帧的情况；
- 使用 ConditionVar：本质上是一个竞争的锁，通过死锁达到睡眠的目的。外部事务可以通知竞争取消来解除锁。比起 Sleep，更适合用在资源管线这种 I/O 申请规模大、不规律的情况。

![sleep-impls](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/sleep-impls.jpg)

在资源管线的 profile 可以看到，file 申请比较大小不一且乱，系统文件缓存的状态也不是那么稳定。有的时候要睡的久，有的时候不怎么需要睡，就需要使用 CondVar 的形式进行睡眠。

![condvar-sleep](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/condvar-sleep.jpg)

## I/O Service的状态查询

不仅是请求的状态，I/O Service 本身的状态查询也是比较重要的。

一个用例是：资源管线会打开多个 ioService 来尽量使用多通道，加速 I/O。在事务申请获取 Service 的时候，就可以检查 Service 是否正在睡眠。任务会被尽量地分配到睡眠状态的 ioService 中，以最大化并发提交。

![query-service-status](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/query-service-status.jpg)

对于资源管线这种提交量大且存在细碎文件的情况下，实测并发提交有着不错的 I/O 效率提升。可能是 OS 对提交进行了 batch，因此比起线性的、单个的提交更快。下图是都使用 CondVar 进行 Sleep 的情况下，一个 Service 对四个 Service 的 profile 结果：

![1iothread](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/20ktasks-1iothread.jpg)

![4iothread](https://media.githubusercontent.com/media/SakuraEngine/Sakura.Resources/main/docs/Runtime/IO/20ktasks-4iothread.jpg)

# 总结

SakuraRuntime 的 ioService 的设计比较充分的考虑了实际情景和平台问题，选项和功能非常多。并且接口是非常 portable 的，不仅限于 PC 这种使用线程模拟 Service 的情形，也适用于拥有真正 I/O Service的平台。