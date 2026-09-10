package internal

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	workerv1 "github.com/easylab-platform/easyworker/gen/worker/v1"
	"github.com/easylab-platform/easyworker/internal/auth"
)

// EnrollService implements workerv1connect.WorkerEnrollHandler: the one-time,
// exclusive claim face. It is only meaningful while the gate is Unclaimed —
// claim succeeds exactly once, returns the worker-issued bearer token, and
// permanently closes the face (later claims → AlreadyExists).
type EnrollService struct {
	gate *auth.Gate
}

func NewEnrollService(gate *auth.Gate) *EnrollService { return &EnrollService{gate: gate} }

func (s *EnrollService) Status(ctx context.Context, req *connect.Request[workerv1.EnrollStatusRequest]) (*connect.Response[workerv1.EnrollStatusResponse], error) {
	st := s.gate.Status()
	return connect.NewResponse(&workerv1.EnrollStatusResponse{
		Claimed:       st.Claimed,
		NeedsCode:     st.NeedsCode,
		Preauthorized: st.Preauthorized,
		BootId:        st.BootID,
	}), nil
}

func (s *EnrollService) Claim(ctx context.Context, req *connect.Request[workerv1.EnrollClaimRequest]) (*connect.Response[workerv1.EnrollClaimResponse], error) {
	tok, err := s.gate.Claim(req.Msg.Code, req.Msg.OwnerId)
	switch {
	case err == nil:
		return connect.NewResponse(&workerv1.EnrollClaimResponse{Ok: true, Token: tok}), nil
	case errors.Is(err, auth.ErrAlreadyClaimed):
		return nil, connect.NewError(connect.CodeAlreadyExists, err)
	case errors.Is(err, auth.ErrRateLimited):
		return nil, connect.NewError(connect.CodeResourceExhausted, err)
	default:
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
}
