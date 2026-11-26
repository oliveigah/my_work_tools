/*
 * MWTClient.ProcessGuard's NIF: marks MWT's own process not dumpable, so
 * no other program running as you can trace it or read its memory through
 * /proc. Linux only, as MWT is.
 */
#include <errno.h>
#include <erl_nif.h>

#ifdef __linux__
#include <sys/prctl.h>
#endif

static ERL_NIF_TERM error(ErlNifEnv *env, ERL_NIF_TERM reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"), reason);
}

/* :ok, or {:error, errno}. */
static ERL_NIF_TERM guard(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
#ifdef __linux__
  if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0) {
    return enif_make_atom(env, "ok");
  }
  return error(env, enif_make_int(env, errno));
#else
  return error(env, enif_make_atom(env, "unsupported"));
#endif
}

/* The process's dumpable setting (0 not, 1 yes, 2 as root), or {:error, errno}. */
static ERL_NIF_TERM dumpable(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
#ifdef __linux__
  int value = prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
  if (value >= 0) {
    return enif_make_int(env, value);
  }
  return error(env, enif_make_int(env, errno));
#else
  return error(env, enif_make_atom(env, "unsupported"));
#endif
}

static ErlNifFunc functions[] = {
    {"guard_nif", 0, guard, 0},
    {"dumpable_nif", 0, dumpable, 0},
};

ERL_NIF_INIT(Elixir.MWTClient.ProcessGuard, functions, NULL, NULL, NULL, NULL)
