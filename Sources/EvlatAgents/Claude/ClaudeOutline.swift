import Foundation

// The mark below is codenotch's outline
// (https://github.com/vinzdg/codenotch, `Sources/Providers/GlyphOutline.swift`),
// used under its licence:
//
// MIT License
//
// Copyright (c) 2026 Vinz
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

extension Claude {
    /// Its mark, traced: a unit box, filled even-odd (`AgentDisplay.outline`).
    static let outline: [[CGPoint]] = [
        [CGPoint(x: 0.2879, y: 0.0108), CGPoint(x: 0.2667, y: 0.0223), CGPoint(x: 0.2423, y: 0.0516), 
         CGPoint(x: 0.2427, y: 0.0873), CGPoint(x: 0.2611, y: 0.1275), CGPoint(x: 0.3425, y: 0.2606), 
         CGPoint(x: 0.3879, y: 0.3474), CGPoint(x: 0.3888, y: 0.3670), CGPoint(x: 0.3695, y: 0.3643), 
         CGPoint(x: 0.2014, y: 0.2351), CGPoint(x: 0.1878, y: 0.2200), CGPoint(x: 0.1552, y: 0.1998), 
         CGPoint(x: 0.1253, y: 0.1950), CGPoint(x: 0.1111, y: 0.1995), CGPoint(x: 0.0877, y: 0.2258), 
         CGPoint(x: 0.0887, y: 0.2565), CGPoint(x: 0.0953, y: 0.2714), CGPoint(x: 0.1180, y: 0.2961), 
         CGPoint(x: 0.1661, y: 0.3284), CGPoint(x: 0.1791, y: 0.3426), CGPoint(x: 0.2965, y: 0.4155), 
         CGPoint(x: 0.3095, y: 0.4297), CGPoint(x: 0.3940, y: 0.4803), CGPoint(x: 0.3974, y: 0.4946), 
         CGPoint(x: 0.3767, y: 0.5004), CGPoint(x: 0.2177, y: 0.4830), CGPoint(x: 0.0404, y: 0.4741), 
         CGPoint(x: 0.0186, y: 0.4808), CGPoint(x: 0.0129, y: 0.4990), CGPoint(x: 0.0276, y: 0.5245), 
         CGPoint(x: 0.0649, y: 0.5375), CGPoint(x: 0.3801, y: 0.5449), CGPoint(x: 0.3943, y: 0.5488), 
         CGPoint(x: 0.3979, y: 0.5574), CGPoint(x: 0.3773, y: 0.5800), CGPoint(x: 0.3130, y: 0.6116), 
         CGPoint(x: 0.2589, y: 0.6470), CGPoint(x: 0.2341, y: 0.6564), CGPoint(x: 0.1360, y: 0.7209), 
         CGPoint(x: 0.1142, y: 0.7485), CGPoint(x: 0.1149, y: 0.7681), CGPoint(x: 0.1416, y: 0.7866), 
         CGPoint(x: 0.1912, y: 0.7787), CGPoint(x: 0.4120, y: 0.6320), CGPoint(x: 0.4270, y: 0.6288), 
         CGPoint(x: 0.4321, y: 0.6332), CGPoint(x: 0.4292, y: 0.6454), CGPoint(x: 0.3940, y: 0.6799), 
         CGPoint(x: 0.3428, y: 0.7530), CGPoint(x: 0.2416, y: 0.8771), CGPoint(x: 0.2334, y: 0.9073), 
         CGPoint(x: 0.2403, y: 0.9269), CGPoint(x: 0.2558, y: 0.9336), CGPoint(x: 0.2734, y: 0.9308), 
         CGPoint(x: 0.3431, y: 0.8618), CGPoint(x: 0.4700, y: 0.6899), CGPoint(x: 0.4807, y: 0.6667), 
         CGPoint(x: 0.4915, y: 0.6611), CGPoint(x: 0.5001, y: 0.6669), CGPoint(x: 0.4995, y: 0.6906), 
         CGPoint(x: 0.4474, y: 0.9569), CGPoint(x: 0.4618, y: 0.9946), CGPoint(x: 0.4901, y: 1.0070), 
         CGPoint(x: 0.5162, y: 0.9945), CGPoint(x: 0.5228, y: 0.9833), CGPoint(x: 0.5369, y: 0.9018), 
         CGPoint(x: 0.5520, y: 0.7109), CGPoint(x: 0.5593, y: 0.6981), CGPoint(x: 0.5814, y: 0.7096), 
         CGPoint(x: 0.6328, y: 0.7971), CGPoint(x: 0.7227, y: 0.9242), CGPoint(x: 0.7395, y: 0.9333), 
         CGPoint(x: 0.7662, y: 0.9315), CGPoint(x: 0.7775, y: 0.9241), CGPoint(x: 0.7830, y: 0.9106), 
         CGPoint(x: 0.7785, y: 0.8597), CGPoint(x: 0.6882, y: 0.7238), CGPoint(x: 0.6753, y: 0.7115), 
         CGPoint(x: 0.6765, y: 0.6956), CGPoint(x: 0.6875, y: 0.6957), CGPoint(x: 0.7252, y: 0.7339), 
         CGPoint(x: 0.8721, y: 0.8489), CGPoint(x: 0.8842, y: 0.8515), CGPoint(x: 0.8959, y: 0.8468), 
         CGPoint(x: 0.9038, y: 0.8373), CGPoint(x: 0.9046, y: 0.8256), CGPoint(x: 0.8530, y: 0.7662), 
         CGPoint(x: 0.6984, y: 0.6269), CGPoint(x: 0.6775, y: 0.6016), CGPoint(x: 0.6778, y: 0.5933), 
         CGPoint(x: 0.6885, y: 0.5908), CGPoint(x: 0.8106, y: 0.6247), CGPoint(x: 0.9440, y: 0.6533), 
         CGPoint(x: 0.9782, y: 0.6467), CGPoint(x: 1.0094, y: 0.6185), CGPoint(x: 0.9968, y: 0.5927), 
         CGPoint(x: 0.9637, y: 0.5647), CGPoint(x: 0.8743, y: 0.5599), CGPoint(x: 0.8332, y: 0.5528), 
         CGPoint(x: 0.7469, y: 0.5529), CGPoint(x: 0.7252, y: 0.5475), CGPoint(x: 0.7138, y: 0.5382), 
         CGPoint(x: 0.7174, y: 0.5299), CGPoint(x: 0.7308, y: 0.5244), CGPoint(x: 0.9772, y: 0.4740), 
         CGPoint(x: 0.9904, y: 0.4655), CGPoint(x: 0.9985, y: 0.4514), CGPoint(x: 1.0037, y: 0.4324), 
         CGPoint(x: 1.0001, y: 0.4183), CGPoint(x: 0.9889, y: 0.4107), CGPoint(x: 0.9616, y: 0.4064), 
         CGPoint(x: 0.8604, y: 0.4200), CGPoint(x: 0.7578, y: 0.4394), CGPoint(x: 0.7164, y: 0.4523), 
         CGPoint(x: 0.7010, y: 0.4468), CGPoint(x: 0.7391, y: 0.3769), CGPoint(x: 0.8619, y: 0.2207), 
         CGPoint(x: 0.8733, y: 0.1749), CGPoint(x: 0.8678, y: 0.1520), CGPoint(x: 0.8528, y: 0.1331), 
         CGPoint(x: 0.8338, y: 0.1217), CGPoint(x: 0.8169, y: 0.1215), CGPoint(x: 0.7888, y: 0.1313), 
         CGPoint(x: 0.7199, y: 0.2007), CGPoint(x: 0.6224, y: 0.3290), CGPoint(x: 0.6034, y: 0.3517), 
         CGPoint(x: 0.5941, y: 0.3541), CGPoint(x: 0.5878, y: 0.3448), CGPoint(x: 0.5875, y: 0.3285), 
         CGPoint(x: 0.6249, y: 0.1713), CGPoint(x: 0.6378, y: 0.0744), CGPoint(x: 0.6253, y: 0.0430), 
         CGPoint(x: 0.6043, y: 0.0257), CGPoint(x: 0.5890, y: 0.0265), CGPoint(x: 0.5661, y: 0.0463), 
         CGPoint(x: 0.5471, y: 0.0805), CGPoint(x: 0.5369, y: 0.2279), CGPoint(x: 0.5259, y: 0.2877), 
         CGPoint(x: 0.5223, y: 0.3461), CGPoint(x: 0.5165, y: 0.3730), CGPoint(x: 0.5080, y: 0.3786), 
         CGPoint(x: 0.4728, y: 0.2909), CGPoint(x: 0.3941, y: 0.1409), CGPoint(x: 0.3647, y: 0.0645), 
         CGPoint(x: 0.3439, y: 0.0282), CGPoint(x: 0.3305, y: 0.0183), CGPoint(x: 0.3013, y: 0.0095), 
         CGPoint(x: 0.2880, y: 0.0108)],
    ]
}
