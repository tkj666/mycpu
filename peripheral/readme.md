# 图片显示到LCD上面

1. 用格式工厂或是window自带的画图将图片转为BMP（24bit）格式
2. 使用正点原子的转化软件将图片转为rgb565格式的coe（16bit）
3. 设置扫描方向为3600  0000（从左到右，从上到下）
4. 设置坐标的范围，坐标的范围一定要和图片的像素完全对齐，不允许出现任何的误差，否则图片的显示会有较大的偏移。比如200 * 199的图片不能因为图方便把LCD的坐标设置为200 * 200
5. 把coe存入bram，然后正常的绘图即可