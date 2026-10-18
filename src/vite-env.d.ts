/// <reference types="vite/client" />

// lottie-web's SVG-only build (no expression engine) ships without its own typings.
declare module "lottie-web/build/player/lottie_light" {
  import lottie from "lottie-web";
  export default lottie;
}
